import Foundation
import OCRCore
#if canImport(Vision)
import OCREngines
#endif

// Phase 2 命令行。子命令：
//   ocr-cli vision <image> [--nocorrect]                 TSV 到 stdout，与 bin/vision-ocr 逐行对拍
//   ocr-cli render <pdf> --page N [--dpi 300] --out x.png  PDFKit 渲染一页（灰度）
//   ocr-cli recognize <pdf> [--pages A-B] [--dpi 300] --out doc.vision.json
//                                                        渲染 + Vision，写引擎契约 JSON

let usage = """
usage:
  ocr-cli vision <image> [--nocorrect]
  ocr-cli render <pdf> --page N [--dpi 300] --out page.png
  ocr-cli recognize <pdf> [--pages A-B] [--dpi 300] --out doc.vision.json

"""

func fail(_ msg: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

func option(_ args: [String], _ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func pageRange(_ spec: String?, count: Int) -> [Int] {
    guard let spec, !spec.isEmpty else { return Array(1...max(1, count)) }
    let parts = spec.split(separator: "-").compactMap { Int($0) }
    if parts.count == 2 { return Array(max(1, parts[0])...min(count, parts[1])) }
    if let n = parts.first { return Array(1...min(count, n)) }
    fail("bad --pages: \(spec)")
}

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { fail(usage) }
args.removeFirst()

#if canImport(Vision)
do {
    switch cmd {
    case "vision":
        guard let path = args.first else { fail(usage) }
        var opts = VisionOptions()
        opts.languageCorrection = !args.contains("--nocorrect")
        let img = try VisionEngine.loadImage(URL(fileURLWithPath: path))
        FileHandle.standardError.write("image: \(img.width)x\(img.height)\n".data(using: .utf8)!)
        let lines = try VisionEngine.recognize(img, options: opts)
        print(lines.map(tsvLine).joined(separator: "\n"))
        FileHandle.standardError.write("lines: \(lines.count)  languageCorrection: \(opts.languageCorrection)\n"
            .data(using: .utf8)!)

    case "render":
        guard let path = args.first, let n = option(args, "--page").flatMap(Int.init),
              let out = option(args, "--out") else { fail(usage) }
        let dpi = option(args, "--dpi").flatMap(Double.init) ?? 300
        let doc = try PageRenderer.open(URL(fileURLWithPath: path))
        let r = try PageRenderer.render(doc, page: n, dpi: dpi)
        try PageRenderer.writePNG(r.image, to: URL(fileURLWithPath: out))

    case "recognize":
        guard let path = args.first, let out = option(args, "--out") else { fail(usage) }
        let dpi = option(args, "--dpi").flatMap(Double.init) ?? 300
        let doc = try PageRenderer.open(URL(fileURLWithPath: path))
        var result = EngineDoc(source: path, engine: "vision", dpi: dpi)
        for n in pageRange(option(args, "--pages"), count: doc.pageCount) {
            let r = try PageRenderer.render(doc, page: n, dpi: dpi)
            let lines = sortReadingOrder(try VisionEngine.recognize(r.image))
            result.pages.append(PageDoc(page: n, width: r.image.width, height: r.image.height,
                                        pdfWidth: r.pdfWidth, pdfHeight: r.pdfHeight, zoom: r.zoom,
                                        rotation: r.rotation, lines: lines))
            FileHandle.standardError.write("page \(n): \(lines.count) lines\n".data(using: .utf8)!)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(result).write(to: URL(fileURLWithPath: out))

    default:
        fail(usage)
    }
} catch {
    fail("\(error)", code: 1)
}
#else
fail("ocr-cli needs macOS (Vision / PDFKit)")
#endif
