// 用 macOS 原生 PDFKit / CoreGraphics 渲染指定页, 统计暗像素占比并跑 Vision 数行数。
// 与 bench/diag_pages.py(MuPDF 渲染)对照, 判断整页空白是不是 MuPDF 的渲染问题。
// 只输出数字; 页图写到 work/bench/diag/pNNNN-pdfkit.png。
//
//   swiftc -O bench/diag_render.swift -o work/bench/diag-render && work/bench/diag-render <pdf> 10 20 62
import AppKit
import Foundation
import PDFKit
import Vision

let args = CommandLine.arguments
guard args.count > 2, let doc = PDFDocument(url: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write("usage: diag-render <pdf> <page>...\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: "work/bench/diag", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let dpi: CGFloat = 360

func render(_ page: PDFPage) -> CGImage? {
    let box = page.bounds(for: .mediaBox)
    let w = Int(box.width * dpi / 72), h = Int(box.height * dpi / 72)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: dpi / 72, y: dpi / 72)
    page.draw(with: .mediaBox, to: ctx)
    return ctx.makeImage()
}

func darkRatio(_ img: CGImage) -> (Double, Double) {
    guard let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return (-1, -1) }
    var d128 = 0, d200 = 0, sum = 0
    for y in 0..<img.height {
        let row = p + y * img.bytesPerRow
        for x in 0..<img.width {
            let v = Int(row[x]); sum += v
            if v < 128 { d128 += 1 }
            if v < 200 { d200 += 1 }
        }
    }
    let n = Double(img.width * img.height)
    return (Double(d128) / n, Double(sum) / n)
}

func visionCount(_ img: CGImage) -> (Int, Int) {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
    try? VNImageRequestHandler(cgImage: img).perform([req])
    let obs = req.results ?? []
    let chars = obs.compactMap { $0.topCandidates(1).first?.string.count }.reduce(0, +)
    return (obs.count, chars)
}

for s in args.dropFirst(2) {
    guard let pno = Int(s), let page = doc.page(at: pno - 1), let img = render(page) else { continue }
    let (d128, mean) = darkRatio(img)
    let (lines, chars) = visionCount(img)
    let url = outDir.appendingPathComponent(String(format: "p%04d-pdfkit.png", pno))
    if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }
    print(String(format: "{\"page\": %d, \"w\": %d, \"h\": %d, \"mean\": %.1f, \"dark_lt128\": %.4f, \"vision_lines\": %d, \"vision_chars\": %d}",
                 pno, img.width, img.height, mean, d128, lines, chars))
}
