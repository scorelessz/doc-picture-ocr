#if canImport(PDFKit)
import Foundation
import OCRCore
import PDFKit

// src/book_pdf.py 的移植：fused.json + 原 PDF → 可搜索 PDF，原页面一字不动，只叠隐形文字层。
//
// 实现与 Python 不同的地方（有意）：
//   - 走增量更新，不是整本重存：源文件字节原样保留，再逐页比图是多余的保险；
//   - 字体用一个空字形的最小 TrueType + ToUnicode，不嵌 Droid：隐形文字不需要字形；
//   - 每字等宽，按行框横向缩放，所以一行之内的字位是按字数比例估的。
//
// 坐标：fused 是显示空间像素（已含 /Rotate，原点左上）。先按页面显示尺寸换成点，再映射回未旋转的
// PDF 空间；CropBox 在这一步直接算进去，不存在 TextWriter 那个取错轴的问题。

public let pdfProducer = "ocr-book-line"

public struct PDFOutOptions: Sendable {
    public var forceText = false            // native_text 的页也嵌字
    public var minRetrieval = 0.98
    public var probePerPage = 2
    public var probe = 200
    public init() {}
}

public struct PlacedLine: Sendable {
    public let x: Double, y: Double, w: Double, h: Double   // 显示空间的点
    public let text: String
}

public struct PDFOutStats: Encodable, Sendable {
    public var pages = 0, pagesEmbedded = 0, pagesSkippedNative = 0, pagesSkippedNativeGate = 0
    public var pagesSkippedNoJSON = 0, pagesSkippedEmpty = 0, pagesRotated = 0
    public var linesIn = 0, linesWritten = 0, linesDropped = 0
    public var sizeIn = 0, sizeOut = 0
    public var warnings: [String] = []
    // 校验
    public var charsIn = 0, charsRetrieved = 0, linesChecked = 0, linesLocated = 0
    public var retrieval: Double?, lineRetrieval: Double?
    public var retrievalWorst: Double?, retrievalWorstPage: Int?
    public var pagesBelowThreshold: [Int] = []
    public var probeChecked = 0, probeFound = 0, probeMissed = 0, probeOutside = 0
    public var probeMeanOffset: Double?, probeMaxOffset: Double?

    enum CodingKeys: String, CodingKey {
        case pages, warnings, retrieval
        case pagesEmbedded = "pages_embedded", pagesSkippedNative = "pages_skipped_native"
        case pagesSkippedNativeGate = "pages_skipped_native_gate", pagesSkippedNoJSON = "pages_skipped_no_json"
        case pagesSkippedEmpty = "pages_skipped_empty", pagesRotated = "pages_rotated"
        case linesIn = "lines_in", linesWritten = "lines_written", linesDropped = "lines_dropped"
        case sizeIn = "size_in", sizeOut = "size_out", charsIn = "chars_in", charsRetrieved = "chars_retrieved"
        case linesChecked = "lines_checked", linesLocated = "lines_located", lineRetrieval = "line_retrieval"
        case retrievalWorst = "retrieval_worst", retrievalWorstPage = "retrieval_worst_page"
        case pagesBelowThreshold = "pages_below_threshold"
        case probeChecked = "probe_checked", probeFound = "probe_found", probeMissed = "probe_missed"
        case probeOutside = "probe_outside", probeMeanOffset = "probe_mean_offset_pt", probeMaxOffset = "probe_max_offset_pt"
    }
}

/// 最小 TrueType：只有 .notdef 一个空字形，单位 1000、字宽 1000。
func glyphlessFont() -> [UInt8] {
    func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 255), UInt8(v & 255)] }
    func be32(_ v: Int) -> [UInt8] { be16(v >> 16) + be16(v & 0xFFFF) }
    let head = be32(0x10000) + be32(0x10000) + be32(0) + be32(0x5F0F3CF5) + be16(0) + be16(1000)
        + be32(0) + be32(0) + be32(0) + be32(0)                      // created / modified
        + be16(0) + be16(0) + be16(1000) + be16(1000)                // bbox
        + be16(0) + be16(8) + be16(2) + be16(0) + be16(0)            // style ppem dir locFmt glyphFmt
    let hhea = be32(0x10000) + be16(800) + be16(65336) + be16(0) + be16(1000)
        + be16(0) + be16(0) + be16(1000) + be16(1) + be16(0) + be16(0)
        + be16(0) + be16(0) + be16(0) + be16(0) + be16(0) + be16(1)
    let maxp = be32(0x10000) + be16(1) + be16(0) + be16(0) + be16(0) + be16(0) + be16(1)
        + be16(0) + be16(0) + be16(0) + be16(0) + be16(0) + be16(0) + be16(0) + be16(0)
    let hmtx = be16(1000) + be16(0)
    let loca = be16(0) + be16(0)
    let tables: [(String, [UInt8])] = [("glyf", []), ("head", head), ("hhea", hhea), ("hmtx", hmtx),
                                       ("loca", loca), ("maxp", maxp)]
    func sum(_ b: [UInt8]) -> Int {
        var s = 0, i = 0
        while i < b.count {
            var v = 0
            for k in 0..<4 { v = v << 8 | (i + k < b.count ? Int(b[i + k]) : 0) }
            s = (s + v) & 0xFFFF_FFFF
            i += 4
        }
        return s
    }
    var out = be32(0x10000) + be16(tables.count) + be16(64) + be16(2) + be16(tables.count * 16 - 64)
    var off = 12 + tables.count * 16
    var body: [UInt8] = []
    for (tag, t) in tables {
        out += Array(tag.utf8) + be32(sum(t)) + be32(off) + be32(t.count)
        let pad = (4 - t.count % 4) % 4
        body += t + [UInt8](repeating: 0, count: pad)
        off += t.count + pad
    }
    return out + body
}

private func utf16BEHex(_ c: Unicode.Scalar) -> String {
    String(c).utf16.map { String(format: "%04X", $0) }.joined()
}

/// 文档级的 CID 表：出现过的码点按顺序编号。CID 0 留给 .notdef。
private struct CIDMap {
    var cid: [UInt32: Int] = [:]
    var order: [Unicode.Scalar] = []

    mutating func hex(_ s: String) -> String {
        var out = ""
        for c in s.unicodeScalars {
            var id = cid[c.value]
            if id == nil {
                id = order.count + 1
                cid[c.value] = id
                order.append(c)
            }
            out += String(format: "%04X", id!)
        }
        return out
    }

    func toUnicode() -> [UInt8] {
        var s = "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n"
            + "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n"
            + "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n"
            + "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n"
        for b in stride(from: 0, to: order.count, by: 100) {
            let part = order[b..<min(b + 100, order.count)]
            s += "\(part.count) beginbfchar\n"
            for (k, c) in part.enumerated() {
                s += String(format: "<%04X> <", b + k + 1) + utf16BEHex(c) + ">\n"
            }
            s += "endbfchar\n"
        }
        s += "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
        return Array(s.utf8)
    }
}

/// 显示空间的向量/点映射回未旋转 PDF 空间。
struct PageGeometry {
    let crop: [Double]
    let rotation: Int

    var displayW: Double { rotation % 180 == 0 ? crop[2] - crop[0] : crop[3] - crop[1] }
    var displayH: Double { rotation % 180 == 0 ? crop[3] - crop[1] : crop[2] - crop[0] }

    func toPDF(_ x: Double, _ y: Double) -> (Double, Double) {
        switch rotation {
        case 90: return (crop[0] + y, crop[1] + x)
        case 180: return (crop[2] - x, crop[1] + y)
        case 270: return (crop[2] - y, crop[3] - x)
        default: return (crop[0] + x, crop[3] - y)
        }
    }

    /// 显示空间里 +x（字的走向）和「向上」在 PDF 空间的方向。
    var axes: (ux: Double, uy: Double, vx: Double, vy: Double) {
        switch rotation {
        case 90: return (0, 1, -1, 0)
        case 180: return (-1, 0, 0, -1)
        case 270: return (0, -1, 1, 0)
        default: return (1, 0, 0, 1)
        }
    }
}

private func num(_ v: Double) -> String {
    var s = String(format: "%.3f", v)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s == "-0" ? "0" : s
}

let heightRatio = 0.95, baselineRatio = 0.84
let minFontSize = 0.5, maxFontSize = 1000.0

public enum PDFOut {
    /// 像素 → 显示空间的点。优先用记录的像素尺寸反推，退回 1/zoom。
    static func scale(_ p: FusedPage, _ g: PageGeometry, _ warn: inout [String]) -> (Double, Double) {
        if p.width > 0, p.height > 0 {
            let sx = g.displayW / Double(p.width), sy = g.displayH / Double(p.height)
            if p.zoom > 0, abs(sx * p.zoom - 1) > 0.02 || abs(sy * p.zoom - 1) > 0.02 {
                warn.append("第\(p.page)页: 像素尺寸反推的比例与 zoom 差 >2%; 按像素尺寸走")
            }
            if abs(sx / sy - 1) > 0.01 { warn.append("第\(p.page)页: x/y 比例不一致, 页面可能被非等比渲染") }
            return (sx, sy)
        }
        return p.zoom > 0 ? (1 / p.zoom, 1 / p.zoom) : (1, 1)
    }

    /// 嵌字。返回新文件字节、各页落笔的行（显示空间，校验用）、统计。
    public static func embed(source: [UInt8], fused: FusedDoc, options o: PDFOutOptions = PDFOutOptions())
        throws -> (bytes: [UInt8], placed: [Int: [PlacedLine]], stats: PDFOutStats) {
        let file = try PDFFile(source)
        let pages = try file.pages()
        var st = PDFOutStats()
        st.pages = pages.count
        st.sizeIn = source.count
        let byPage = Dictionary(fused.pages.map { ($0.page, $0) }, uniquingKeysWith: { _, b in b })
        if !Set(byPage.keys).subtracting(1...max(1, pages.count)).isEmpty {
            st.warnings.append("fused.json 有超出 PDF 页数(\(pages.count))的页号, 已忽略")
        }

        let up = try PDFUpdater(file)
        var cids = CIDMap()
        var placedAll: [Int: [PlacedLine]] = [:]
        // 先留好共用对象的号：页面要引用字体
        let fontObj = up.allocate(), cidFontObj = up.allocate(), descObj = up.allocate()
        let fileObj = up.allocate(), cmapObj = up.allocate(), qObj = up.allocate()
        let fontName = "OCRTXT"

        for (i, pr) in pages.enumerated() {
            let n = i + 1
            guard let pj = byPage[n] else {
                st.pagesSkippedNoJSON += 1
                st.warnings.append("第\(n)页: fused.json 里没有这一页, 不嵌字")
                continue
            }
            // 白页闸门改用了文字层的页：文字本来就在页上，再嵌就重复了
            if pj.textSource == "native_text" {
                st.pagesSkippedNativeGate += 1
                continue
            }
            if pj.nativeText, !o.forceText {
                st.pagesSkippedNative += 1
                continue
            }
            st.linesIn += pj.lines.count
            let g = PageGeometry(crop: pr.crop, rotation: pr.rotation)
            if pr.rotation != 0 { st.pagesRotated += 1 }
            if pj.rotation != pr.rotation {
                st.warnings.append("第\(n)页: fused.json 记录 rotation=\(pj.rotation), PDF 实际是 \(pr.rotation); 按 PDF 实际值处理")
            }
            let (sx, sy) = scale(pj, g, &st.warnings)

            var placed: [PlacedLine] = []
            var content = "Q\nq\nBT\n3 Tr\n"
            let ax = g.axes
            for ln in pj.lines {
                let text = pyStrip(ln.text)
                let X = ln.x * sx, Y = ln.y * sy, W = ln.w * sx, H = ln.h * sy
                guard !text.unicodeScalars.isEmpty, X.isFinite, Y.isFinite, W > 0, H > 0 else {
                    st.linesDropped += 1
                    continue
                }
                let count = Double(codePointCount(text))
                let fs = min(max(H * heightRatio, minFontSize), maxFontSize)
                let hs = W / (count * fs)            // 字宽 = 字号，横向缩放到正好填满行框
                let (ex, ey) = g.toPDF(X, Y + H * baselineRatio)
                content += "/\(fontName) \(num(fs)) Tf "
                    + "\(num(ax.ux * hs)) \(num(ax.uy * hs)) \(num(ax.vx)) \(num(ax.vy)) \(num(ex)) \(num(ey)) Tm "
                    + "<\(cids.hex(text))> Tj\n"
                placed.append(PlacedLine(x: X, y: Y, w: W, h: H, text: text))
            }
            content += "ET\nQ\n"
            if placed.isEmpty {
                st.pagesSkippedEmpty += 1
                continue
            }

            let textObj = up.allocate()
            up.setStream(textObj, data: Array(content.utf8))

            // 新页面对象：Contents 夹一层 q/Q，Resources 内联并加上字体
            var contents: [PDFValue] = [.ref(qObj, 0)]
            if let c = pr.dict["Contents"] {
                if case .array(let a) = try file.resolve(c) { contents += a } else { contents.append(c) }
            }
            contents.append(.ref(textObj, 0))

            var res = try pr.resources.map(file.resolve)?.dictItems ?? []
            var fonts = try res.first { $0.0 == "Font" }.map { try file.resolve($0.1) }?.dictItems ?? []
            fonts.removeAll { $0.0 == fontName }
            fonts.append((fontName, .ref(fontObj, 0)))
            res.removeAll { $0.0 == "Font" }
            res.append(("Font", .dict(fonts)))

            var d = pr.dict.dictItems ?? []
            d.removeAll { $0.0 == "Contents" || $0.0 == "Resources" }
            d += [("Contents", .array(contents)), ("Resources", .dict(res))]
            up.setObject(pr.obj, gen: pr.gen, .dict(d))

            st.pagesEmbedded += 1
            st.linesWritten += placed.count
            placedAll[n] = placed
        }

        // 共用对象
        up.setStream(qObj, data: Array("q\n".utf8), compress: false)
        let ff = glyphlessFont()
        up.setStream(fileObj, dict: [("Length1", .number("\(ff.count)"))], data: ff)
        up.setStream(cmapObj, data: cids.toUnicode())
        up.setObject(descObj, .dict([
            ("Type", .name("FontDescriptor")), ("FontName", .name("GlyphLessFont")), ("Flags", .number("4")),
            ("FontBBox", .array(["0", "0", "1000", "1000"].map { .number($0) })), ("ItalicAngle", .number("0")),
            ("Ascent", .number("800")), ("Descent", .number("-200")), ("CapHeight", .number("800")),
            ("StemV", .number("0")), ("FontFile2", .ref(fileObj, 0)),
        ]))
        up.setObject(cidFontObj, .dict([
            ("Type", .name("Font")), ("Subtype", .name("CIDFontType2")), ("BaseFont", .name("GlyphLessFont")),
            ("CIDSystemInfo", .dict([("Registry", .string(Array("(Adobe)".utf8))),
                                     ("Ordering", .string(Array("(Identity)".utf8))),
                                     ("Supplement", .number("0"))])),
            ("FontDescriptor", .ref(descObj, 0)), ("DW", .number("1000")), ("CIDToGIDMap", .name("Identity")),
        ]))
        up.setObject(fontObj, .dict([
            ("Type", .name("Font")), ("Subtype", .name("Type0")), ("BaseFont", .name("GlyphLessFont")),
            ("Encoding", .name("Identity-H")), ("DescendantFonts", .array([.ref(cidFontObj, 0)])),
            ("ToUnicode", .ref(cmapObj, 0)),
        ]))

        // 归属章：--force 靠它认「这份 PDF 是不是本线写的」
        var info = try file.trailer["Info"].map(file.resolve)?.dictItems ?? []
        info.removeAll { $0.0 == "Producer" }
        info.append(("Producer", .string(Array("(\(pdfProducer))".utf8))))
        let infoRef: PDFValue
        if case .ref(let n, let g)? = file.trailer["Info"] {
            up.setObject(n, gen: g, .dict(info))
            infoRef = .ref(n, g)
        } else {
            let n = up.allocate()
            up.setObject(n, .dict(info))
            infoRef = .ref(n, 0)
        }

        let out = up.finish(info: infoRef)
        st.sizeOut = out.count
        return (out, placedAll, st)
    }

    // MARK: 校验（book_pdf._verify 的口径）

    /// 该页每个字的中心（显示空间的点）和字本身。PDFKit 的 characterBounds 是未旋转页面坐标。
    static func pageChars(_ page: PDFPage) -> [(x: Double, y: Double, c: Unicode.Scalar)] {
        guard let s = page.string else { return [] }
        let box = page.bounds(for: .cropBox)
        let g = PageGeometry(crop: [Double(box.minX), Double(box.minY), Double(box.maxX), Double(box.maxY)],
                             rotation: ((page.rotation % 360) + 360) % 360)
        var out: [(x: Double, y: Double, c: Unicode.Scalar)] = []
        var i = 0
        for c in s.unicodeScalars {
            defer { i += c.utf16Count }
            if isPySpace(c) { continue }
            // characterBounds 对隐形字不可靠：高度全 0，不少字直接返回 (0,0,0,0)。selection 的框是对的。
            guard let sel = page.selection(for: NSRange(location: i, length: c.utf16Count)) else { continue }
            let b = sel.bounds(for: page)
            if b.isNull || b.width == 0 { continue }
            let (x, y) = toDisplay(Double(b.midX), Double(b.midY), g)
            out.append((x, y, c))
        }
        return out
    }

    private static func toDisplay(_ ux: Double, _ uy: Double, _ g: PageGeometry) -> (Double, Double) {
        let c = g.crop
        switch g.rotation {
        case 90: return (uy - c[1], ux - c[0])
        case 180: return (c[2] - ux, uy - c[1])
        case 270: return (c[3] - uy, c[2] - ux)
        default: return (ux - c[0], c[3] - uy)
        }
    }

    private static func near(_ l: PlacedLine, _ chars: [(x: Double, y: Double, c: Unicode.Scalar)]) -> [UInt32: Int] {
        let pad = max(l.h * 0.6, 1)
        var c: [UInt32: Int] = [:]
        for p in chars where p.x >= l.x - pad && p.x < l.x + l.w + pad && p.y >= l.y - pad && p.y < l.y + l.h + pad {
            c[p.c.value, default: 0] += 1
        }
        return c
    }

    private static func snippet(_ t: String) -> String {
        let u = Array(pyStrip(t).unicodeScalars)
        if u.count < 2 { return "" }
        let part = u.count <= 8 ? u[...] : u[((u.count - 8) / 2)..<((u.count - 8) / 2 + 8)]
        var v = String.UnicodeScalarView()
        v.append(contentsOf: part)
        return pyStrip(String(v))
    }

    /// 逐行定位取回率：每行的字必须出现在它自己 bbox 的邻域，且先扣掉源 PDF 同一邻域本来就有的字。
    public static func verify(output: PDFDocument, source: PDFDocument, placed: [Int: [PlacedLine]],
                              options o: PDFOutOptions, stats st: inout PDFOutStats) {
        var worst = (2.0, 0)
        for (n, items) in placed.sorted(by: { $0.key < $1.key }) {
            guard let pg = output.page(at: n - 1) else { continue }
            let chars = pageChars(pg)
            let base = source.page(at: n - 1).map(pageChars) ?? []
            var pIn = 0, pHit = 0
            for l in items {
                var want: [UInt32: Int] = [:]
                for c in l.text.unicodeScalars where !isPySpace(c) { want[c.value, default: 0] += 1 }
                let total = want.values.reduce(0, +)
                if total == 0 { continue }
                let got = near(l, chars), had = near(l, base)
                var hit = 0
                for (k, v) in want { hit += min(v, max(0, (got[k] ?? 0) - (had[k] ?? 0))) }
                st.linesChecked += 1
                if hit == total { st.linesLocated += 1 }
                pIn += total
                pHit += hit
            }
            st.charsIn += pIn
            st.charsRetrieved += pHit
            let r = pIn > 0 ? Double(pHit) / Double(pIn) : 1
            if r < worst.0 { worst = (r, n) }
            if r < o.minRetrieval { st.pagesBelowThreshold.append(n) }
        }
        if st.charsIn > 0 {
            st.retrieval = pyRound(Double(st.charsRetrieved) / Double(st.charsIn), 4)
            st.lineRetrieval = pyRound(Double(st.linesLocated) / Double(st.linesChecked), 4)
            st.retrievalWorst = pyRound(worst.0, 4)
            st.retrievalWorstPage = worst.1
            if st.retrieval! < o.minRetrieval {
                st.warnings.append("逐行字符取回率 \(st.retrieval!) 低于阈值 \(o.minRetrieval); 最差第\(worst.1)页")
            }
        } else {
            st.warnings.append("本书未识别出任何文字: 没有一行被嵌进文字层, 取回率无从谈起(不是 1.0000)")
        }

        // 定位抽查：每页 probePerPage 条，全书不超过 probe 条，按页抽样
        var pages = placed.keys.sorted().filter { p in placed[p]!.contains { !snippet($0.text).isEmpty } }
        let wantPages = max(1, o.probe / max(1, o.probePerPage))
        if pages.count > wantPages {
            let step = Double(pages.count) / Double(wantPages)
            pages = (0..<wantPages).map { pages[min(pages.count - 1, Int(Double($0) * step))] }
        }
        var offsets: [Double] = []
        for n in pages {
            guard let pg = output.page(at: n - 1) else { continue }
            let pool = placed[n]!.filter { !snippet($0.text).isEmpty }
            let k = min(o.probePerPage, pool.count), step = max(1, pool.count / k)
            for idx in stride(from: 0, to: pool.count, by: step).prefix(k) {
                let l = pool[idx]
                st.probeChecked += 1
                let snip = snippet(l.text)
                let core = Array(pyStrip(l.text).unicodeScalars), sn = Array(snip.unicodeScalars)
                var start = 0
                for s in 0...(core.count - sn.count) where Array(core[s..<(s + sn.count)]) == sn {
                    start = s
                    break
                }
                let wantX = l.x + l.w * (Double(start) + Double(sn.count) / 2) / Double(core.count)
                let wantY = l.y + l.h / 2
                let hits = output.findString(snip, withOptions: [.literal]).filter { $0.pages.first == pg }
                if hits.isEmpty {
                    st.probeMissed += 1
                    continue
                }
                let box = pg.bounds(for: .cropBox)
                let g = PageGeometry(crop: [Double(box.minX), Double(box.minY), Double(box.maxX), Double(box.maxY)],
                                     rotation: ((pg.rotation % 360) + 360) % 360)
                let cs = hits.map { h -> (Double, Double) in
                    let b = h.bounds(for: pg)
                    return toDisplay(Double(b.midX), Double(b.midY), g)
                }
                let d = cs.map { (($0.0 - wantX) * ($0.0 - wantX) + ($0.1 - wantY) * ($0.1 - wantY)).squareRoot() }
                let i = d.indices.min { d[$0] < d[$1] }!
                offsets.append(d[i])
                st.probeFound += 1
                if !(cs[i].0 >= l.x && cs[i].0 <= l.x + l.w && cs[i].1 >= l.y - l.h / 2 && cs[i].1 <= l.y + l.h * 1.5) {
                    st.probeOutside += 1
                }
            }
        }
        if !offsets.isEmpty {
            st.probeMeanOffset = pyRound(offsets.reduce(0, +) / Double(offsets.count), 2)
            st.probeMaxOffset = pyRound(offsets.max()!, 2)
        }
        if st.probeMissed > 0 { st.warnings.append("定位抽查有 \(st.probeMissed)/\(st.probeChecked) 条搜索没命中") }
        if st.probeOutside > 0 { st.warnings.append("定位抽查有 \(st.probeOutside)/\(st.probeFound) 条命中框中心落在该行 bbox 之外") }
    }
}

/// 嵌字、写 .part、校验、改名：校验没跑完不留成品。
public func writeSearchablePDF(src: URL, fused: FusedDoc, out: URL,
                               options o: PDFOutOptions = PDFOutOptions()) throws -> PDFOutStats {
    let source = [UInt8](try Data(contentsOf: src))
    var (bytes, placed, st) = try PDFOut.embed(source: source, fused: fused, options: o)
    let part = out.deletingLastPathComponent().appendingPathComponent(out.lastPathComponent + ".part")
    try Data(bytes).write(to: part)
    bytes = []
    do {
        guard let od = PDFDocument(url: part), let sd = PDFDocument(url: src) else {
            throw PDFError.malformed("写出的 PDF 打不开")
        }
        guard od.pageCount == st.pages else { throw PDFError.malformed("写出的 PDF 页数不对: \(od.pageCount)") }
        PDFOut.verify(output: od, source: sd, placed: placed, options: o, stats: &st)
        _ = try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: part, to: out)
    } catch {
        try? FileManager.default.removeItem(at: part)
        throw error
    }
    return st
}

private extension Unicode.Scalar {
    var utf16Count: Int { value > 0xFFFF ? 2 : 1 }
}
#endif
