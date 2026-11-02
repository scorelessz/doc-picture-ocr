#if canImport(PDFKit)
import CoreGraphics
import Foundation
import ImageIO
import PDFKit

// PDFKit / CoreGraphics 渲染页面，取代 pymupdf（AGPL）。
// 坐标约定与 Python 书籍线相同：像素 = 视觉 PDF 点 × zoom，原点左上；已含 /Rotate。

public enum PageRendererError: Error, CustomStringConvertible {
    case cannotOpen(String), noPage(Int), cannotRender(Int), cannotWrite(String)

    public var description: String {
        switch self {
        case .cannotOpen(let p): return "cannot open pdf: \(p)"
        case .noPage(let n): return "no page \(n)"
        case .cannotRender(let n): return "cannot render page \(n)"
        case .cannotWrite(let p): return "cannot write \(p)"
        }
    }
}

public struct RenderedPage {
    public let image: CGImage
    public let zoom: Double
    public let pdfWidth: Double      // 视觉宽（点），已含旋转
    public let pdfHeight: Double
    public let rotation: Int
}

public enum PageRenderer {
    public static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw PageRendererError.cannotOpen(url.path) }
        return doc
    }

    /// 渲染第 `number` 页（从 1 开始，PDF 文件里的绝对页序）为灰度图。
    public static func render(_ doc: PDFDocument, page number: Int, dpi: Double) throws -> RenderedPage {
        guard let page = doc.page(at: number - 1) else { throw PageRendererError.noPage(number) }
        let box = page.bounds(for: .cropBox)
        let rot = ((page.rotation % 360) + 360) % 360
        let (vw, vh) = rot == 90 || rot == 270 ? (box.height, box.width) : (box.width, box.height)
        let zoom = dpi / 72.0
        // 向外取整，与 pymupdf 的 fz_irect_from_rect 一致：差 1 像素，页图尺寸就对不上
        let w = Int((Double(vw) * zoom - 0.001).rounded(.up)), h = Int((Double(vh) * zoom - 0.001).rounded(.up))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw PageRendererError.cannotRender(number)
        }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // 画布比页面略大时，内容贴左上角（CGContext 原点在左下）
        ctx.translateBy(x: 0, y: CGFloat(Double(h) - Double(vh) * zoom))
        ctx.scaleBy(x: zoom, y: zoom)
        // PDFPage.draw 会按页面的 /Rotate 摆正内容
        page.draw(with: .cropBox, to: ctx)
        guard let img = ctx.makeImage() else { throw PageRendererError.cannotRender(number) }
        return RenderedPage(image: img, zoom: zoom, pdfWidth: Double(vw), pdfHeight: Double(vh), rotation: rot)
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw PageRendererError.cannotWrite(url.path)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw PageRendererError.cannotWrite(url.path) }
    }
}
#endif
