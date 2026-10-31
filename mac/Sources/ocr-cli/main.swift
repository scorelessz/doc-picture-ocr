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
  ocr-cli fuse <vision.json> <rapidocr.json> --out fused.json [--legacy] [--force]
  ocr-cli md <fused.json> --out out.md [--no-page-marks] [--force] [--stats stats.json]

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

    case "fuse":
        guard args.count >= 2, let out = option(args, "--out") else { fail(usage) }
        let outURL = URL(fileURLWithPath: out)
        // 已存在就拒绝写：work/ 下的旧文件可能是别的会话的输入
        if FileManager.default.fileExists(atPath: out), !args.contains("--force") {
            fail("输出已存在, 拒绝覆盖: \(out)（要覆盖请加 --force）", code: 1)
        }
        let dec = JSONDecoder()
        var docs: [String: EngineDoc] = [:]
        for p in args[0...1] {
            let d = try dec.decode(EngineDoc.self, from: Data(contentsOf: URL(fileURLWithPath: p)))
            docs[d.engine] = d
        }
        guard let v = docs["vision"], let r = docs["rapidocr"] else {
            fail("需要 vision 与 rapidocr 各一份", code: 1)
        }
        var rules = FuseRules()
        rules.legacyContain = args.contains("--legacy")
        let fused = try fuse(v, r, rules: rules)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(fused).write(to: outURL)
        let st = fused.stats
        print("页 \(st.pages)  行 \(st.lines)  双引擎 \(st.both)  分歧 \(st.divergent)  "
              + "仅vision \(st.onlyVision)  仅rapidocr \(st.onlyRapidocr)  丢弃重影 \(st.droppedContained)")

    case "md":
        guard let path = args.first, let out = option(args, "--out") else { fail(usage) }
        // output/ 下的 md 可能是别的流程的输入：已存在就拒绝写
        if FileManager.default.fileExists(atPath: out), !args.contains("--force") {
            fail("拒绝覆盖已存在的文件: \(out)（要覆盖请加 --force）", code: 3)
        }
        let doc = try JSONDecoder().decode(MDDoc.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        var o = MDOptions()
        o.pageMarks = !args.contains("--no-page-marks")
        let (md, st) = toMarkdown(doc, options: o)
        try withMark(md).write(to: URL(fileURLWithPath: out), atomically: true, encoding: .utf8)
        if let sp = option(args, "--stats") {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try enc.encode(st).write(to: URL(fileURLWithPath: sp))
        }
        print("页 \(st.pages)  原始行 \(st.linesIn)  合行后 \(st.rows)  正文行 \(st.keptRows)  "
              + "丢弃 \(st.dropped)  标题 \(st.headings)  段落 \(st.paragraphs)  正文 \(st.chars) 字")

    default:
        fail(usage)
    }
} catch {
    fail("\(error)", code: 1)
}
#else
fail("ocr-cli needs macOS (Vision / PDFKit)")
#endif
