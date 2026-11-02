#if canImport(PDFKit)
import CoreGraphics
import Foundation
import OCRCore
import PDFKit

// python-final:src/book_render.py 分辨率与原生文字层部分的移植：choose_dpi / embedded_dpi / has_native_text / native_lines。
// PDFKit 没有列内嵌图的接口，用 CGPDFScanner 走内容流：跟踪 q/Q/cm，遇到 Do 取图像字典，
// Form XObject 递归进去（pymupdf 的 get_image_info 也会看到表单里的图）。行内图（BI/EI）不统计。

public enum RenderDefaults {
    public static let baseDPI = 300.0, maxDPI = 600.0
    public static let maxPixels = 80_000_000.0
    /// 小图（logo/插图）不参与原生 dpi 判定
    public static let minImageCoverage = 0.40
    public static let nativeMinChars = 50
    /// 暗像素（<128）占比低于它算「无墨迹」。基准书无内容页最高 0.00009；
    /// 有内容页最低 0.00077（英文第 2 页只有两个印章字），所以不能用 0.001。
    public static let noInkDark = 0.0003
}

public struct EmbeddedImage: Sendable {
    public let width: Int, height: Int
    public let area: Double            // 在页面上占的外接矩形面积（点²）
}

private final class ScanState {
    var ctm = CGAffineTransform.identity
    var stack: [CGAffineTransform] = []
    var images: [EmbeddedImage] = []
    var depth = 0
    let table: CGPDFOperatorTableRef

    init(table: CGPDFOperatorTableRef) { self.table = table }

    func addImage(_ dict: CGPDFDictionaryRef) {
        var w: CGPDFInteger = 0, h: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dict, "Width", &w), CGPDFDictionaryGetInteger(dict, "Height", &h) else { return }
        let r = CGRect(x: 0, y: 0, width: 1, height: 1).applying(ctm)
        images.append(EmbeddedImage(width: w, height: h, area: Double(r.width * r.height)))
    }
}

private func state(_ info: UnsafeMutableRawPointer?) -> ScanState {
    Unmanaged<ScanState>.fromOpaque(info!).takeUnretainedValue()
}

private func formMatrix(_ dict: CGPDFDictionaryRef) -> CGAffineTransform {
    var arr: CGPDFArrayRef?
    guard CGPDFDictionaryGetArray(dict, "Matrix", &arr), let arr, CGPDFArrayGetCount(arr) == 6 else { return .identity }
    var v = [CGPDFReal](repeating: 0, count: 6)
    for i in 0..<6 where !CGPDFArrayGetNumber(arr, i, &v[i]) { return .identity }
    return CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
}

private func scanStream(_ cs: CGPDFContentStreamRef, _ st: ScanState) {
    let scanner = CGPDFScannerCreate(cs, st.table, Unmanaged.passUnretained(st).toOpaque())
    CGPDFScannerScan(scanner)
    CGPDFScannerRelease(scanner)
}

private func makeTable() -> CGPDFOperatorTableRef {
    let t = CGPDFOperatorTableCreate()!
    CGPDFOperatorTableSetCallback(t, "q") { _, info in
        let s = state(info)
        s.stack.append(s.ctm)
    }
    CGPDFOperatorTableSetCallback(t, "Q") { _, info in
        let s = state(info)
        if let m = s.stack.popLast() { s.ctm = m }
    }
    CGPDFOperatorTableSetCallback(t, "cm") { scanner, info in
        var v = [CGPDFReal](repeating: 0, count: 6)
        for i in (0..<6).reversed() where !CGPDFScannerPopNumber(scanner, &v[i]) { return }
        let s = state(info)
        s.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(s.ctm)
    }
    CGPDFOperatorTableSetCallback(t, "Do") { scanner, info in
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &name), let name else { return }
        let cs = CGPDFScannerGetContentStream(scanner)
        guard let obj = CGPDFContentStreamGetResource(cs, "XObject", name) else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(obj, .stream, &stream), let stream,
              let dict = CGPDFStreamGetDictionary(stream) else { return }
        var sub: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dict, "Subtype", &sub), let sub else { return }
        let s = state(info)
        switch String(cString: sub) {
        case "Image":
            s.addImage(dict)
        case "Form" where s.depth < 8:
            var res: CGPDFDictionaryRef?
            // 没有自己 /Resources 的老式表单不递归：CGPDFContentStreamCreateWithStream 不接受空资源
            guard CGPDFDictionaryGetDictionary(dict, "Resources", &res), let res else { return }
            let saved = s.ctm, savedStack = s.stack
            s.ctm = formMatrix(dict).concatenating(s.ctm)
            s.depth += 1
            let inner = CGPDFContentStreamCreateWithStream(stream, res, cs)
            scanStream(inner, s)
            CGPDFContentStreamRelease(inner)
            s.depth -= 1
            s.ctm = saved
            s.stack = savedStack
        default:
            break
        }
    }
    return t
}

public enum PageInspect {
    public static func images(_ page: PDFPage) -> [EmbeddedImage] {
        guard let ref = page.pageRef else { return [] }
        let table = makeTable()
        defer { CGPDFOperatorTableRelease(table) }
        let st = ScanState(table: table)
        let cs = CGPDFContentStreamCreateWithPage(ref)
        scanStream(cs, st)
        CGPDFContentStreamRelease(cs)
        return st.images
    }

    /// 该页内嵌图的原生 dpi；没有够大的图就 nil。面积开方，图被转过 90° 也成立。
    public static func embeddedDPI(_ page: PDFPage) -> Double? {
        let box = page.bounds(for: .cropBox)
        let pageArea = Double(box.width * box.height)
        if pageArea <= 0 { return nil }
        var best: Double?
        for im in images(page) where im.area > 0 && im.width > 0 && im.height > 0 {
            if im.area < RenderDefaults.minImageCoverage * pageArea { continue }
            let d = 72.0 * (Double(im.width * im.height) / im.area).squareRoot()
            best = max(best ?? d, d)
        }
        return best
    }

    /// max(base, 原生) 再夹到 maxDPI 和总像素上限内。
    public static func chooseDPI(_ page: PDFPage, base: Double = RenderDefaults.baseDPI,
                                 maxDPI: Double = RenderDefaults.maxDPI,
                                 maxPixels: Double = RenderDefaults.maxPixels) -> Double {
        var dpi = base
        if let nat = embeddedDPI(page), nat > dpi { dpi = nat }
        dpi = min(dpi, maxDPI)
        let box = page.bounds(for: .cropBox)
        let ptArea = Double(box.width * box.height)
        if ptArea > 0, ptArea * (dpi / 72) * (dpi / 72) > maxPixels {
            dpi = 72 * (maxPixels / ptArea).squareRoot()
        }
        return max(dpi.rounded(.toNearestOrEven), 1)
    }

    /// 灰度图里暗像素（<128）的占比。
    public static func darkRatio(_ image: CGImage) -> Double {
        guard image.bitsPerPixel == 8, let data = image.dataProvider?.data, let p = CFDataGetBytePtr(data),
              image.width > 0, image.height > 0 else { return -1 }
        var dark = 0
        for y in 0..<image.height {
            let row = p + y * image.bytesPerRow
            for x in 0..<image.width where row[x] < 128 { dark += 1 }
        }
        return Double(dark) / Double(image.width * image.height)
    }

    public static func hasNativeText(_ page: PDFPage) -> Bool {
        codePointCount(pyStrip(page.string ?? "")) >= RenderDefaults.nativeMinChars
    }

    /// 原生文字层按行取出，换成流水线坐标：像素，原点左上，已含旋转。conf 记 0：这不是识别结果。
    public static func nativeLines(_ page: PDFPage, zoom: Double, visualHeight: Double) -> [Line] {
        guard let sel = page.selection(for: page.bounds(for: .cropBox)) else { return [] }
        let tf = page.transform(for: .cropBox)
        var out: [Line] = []
        for ls in sel.selectionsByLine() {
            let text = pyStrip(ls.string ?? "")
            if text.unicodeScalars.isEmpty { continue }
            let r = ls.bounds(for: page).applying(tf)
            out.append(Line(x: Double(r.minX) * zoom, y: (visualHeight - Double(r.maxY)) * zoom,
                            w: Double(r.width) * zoom, h: Double(r.height) * zoom, conf: 0, text: text))
        }
        return out
    }
}
#endif
