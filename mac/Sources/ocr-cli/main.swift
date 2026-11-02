import Foundation
import OCRCore
#if canImport(Vision)
import CoreML
import OCREngines
import OCRProviders
import OCRVL
#endif

// Phase 2 命令行。子命令：
//   ocr-cli vision <image> [--nocorrect]                 TSV 到 stdout，与 bin/vision-ocr 逐行对拍
//   ocr-cli render <pdf> --page N [--dpi 300] --out x.png  PDFKit 渲染一页（灰度）
//   ocr-cli recognize <pdf> [--pages A-B|a,b,c] [--dpi N] --out doc.vision.json
//                                                        渲染 + 白页闸门 + Vision，写引擎契约 JSON；
//                                                        不给 --dpi 时逐页按内嵌图分辨率定
//   ocr-cli page-info <pdf> [--pages A-B|a,b,c] [--ink] --out info.json
//                                                        只出每页 dpi / 尺寸 / 文字层字数，--ink 再量暗像素
//   ocr-cli fuse / ocr-cli md                            见 usage

let usage = """
usage:
  ocr-cli vision <image> [--nocorrect]
  ocr-cli render <pdf> --page N [--dpi 300] --out page.png
  ocr-cli recognize <pdf> [--pages A-B|a,b,c] [--dpi N] --out doc.vision.json
  ocr-cli page-info <pdf> [--pages A-B|a,b,c] [--ink] --out info.json
  ocr-cli fuse <vision.json> <rapidocr.json> --out fused.json [--legacy] [--force]
  ocr-cli md <fused.json> --out out.md [--no-page-marks] [--vlm-breaks] [--force] [--stats stats.json]
  ocr-cli pdf <源.pdf> <fused.json> --out x.searchable.pdf [--force] [--force-text] [--stats stats.json]
  ocr-cli paddle <image>... --models dir [--units ane|all|cpu|gpu] [--cls] --out lines.json
  ocr-cli vlm-fuse <fused.json> --vlm-dir dir --out fused.vlm.json [--report r.json]
  ocr-cli vl <image>... --vl-model dir --out texts.json
  ocr-cli doctor [--models-dir dir] [--outdir output] [--out checks.json]
  ocr-cli models fetch [--models-dir dir] [--url u] [--sha256 h]
  ocr-cli models fetch --vl [--models-dir dir] [--url 基址]
  ocr-cli adjudicate <fused.json> --provider id --model m --out o.json --allow-network [--mode image|text] [--pdf p]
                     [--pages 1,2] [--online-jobs 1-8] [--confirm-upload 清单sha256] [--key-stdin] [--force]
  ocr-cli verify-uploads <report.md> <uploads.jsonl>
  ocr-cli history list
  ocr-cli history prune (--older-than 30d | --unfinished | --all) [--work] [--trash-outputs] [--dry-run] [--yes]
                        默认只预览，加 --yes 才执行；输出文件只进废纸篓
  ocr-cli provider list
  ocr-cli provider key set|status|delete <id>   Key 从 stdin 读，不接受参数
  ocr-cli provider models <id> --allow-network [--key-stdin]
  ocr-cli provider probe <id> --allow-network --model m [--key-stdin]
  ocr-cli paddle-plan --models dir --out plan.json
  ocr-cli book <pdf> [--outdir output] [--workdir work] [--md|--no-md] [--pdf|--no-pdf] [--pages A-B|a,b,c]
               [--page-marks none|comment|rule] [--force] [--clobber] [--force-ocr] [--keep-pages]
               [--paddle coreml|python] [--models-dir dir] [--units ane|all|cpu|gpu]
               [--vlm [--vl-model dir] [--vlm-all] | --vlm-url http://127.0.0.1:端口/v1 [--vlm-model 名]]
               [--vlm-provider id --vlm-model 名 --allow-network [--online-jobs 1-8] [--confirm-upload 清单sha256] [--key-stdin]]
               [--python .venv/bin/python] [--result result.json]


所有子命令: --log-level error|warn|info|debug|trace  --log-file 路径  --log-format json|text  --log-text
            环境变量 DOCOCR_LOG 等价于 --log-level; 默认不写识别正文, --log-text 才写
"""

func fail(_ msg: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

/// 给人看的提示走 stderr；同一条也进诊断日志。⚠ 记 warn 并带页号，其余是进度，记 debug。
func warn(_ msg: String) {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    guard Log.shared.enabled else { return }
    if msg.hasPrefix("⚠") {
        var f: [String: LogValue] = ["message": .s(msg)]
        if let r = msg.range(of: #"第 \d+ 页"#, options: .regularExpression),
           let n = Int(msg[r].filter(\.isNumber)) {
            f["page"] = .i(n)
        }
        Log.shared.warn("warning", f)
    } else {
        Log.shared.debug("progress", ["message": .s(msg)])
    }
}

func option(_ args: [String], _ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func pageRange(_ spec: String?, count: Int) -> [Int] {
    guard let spec, !spec.isEmpty else { return Array(1...max(1, count)) }
    if spec.contains(",") {
        return spec.split(separator: ",").flatMap { pageRange(String($0).contains("-") ? String($0) : "\($0)-\($0)", count: count) }
    }
    let parts = spec.split(separator: "-").compactMap { Int($0) }
    if parts.count == 2 { return Array(max(1, parts[0])...min(count, parts[1])) }
    if let n = parts.first { return Array(1...min(count, n)) }
    fail("bad --pages: \(spec)")
}

var args: [String]
do {
    args = try Log.shared.configure(Array(CommandLine.arguments.dropFirst()), env: ProcessInfo.processInfo.environment)
} catch {
    fail("\(error)")
}
guard let cmd = args.first else { fail(usage) }
args.removeFirst()
let startedAt = Date()

#if canImport(Vision)
// --models-dir 优先，--models 是旧写法
let defaultModels = option(args, "--models-dir") ?? option(args, "--models") ?? ModelStore.defaultDirectory.path
logEnvironment(args: [cmd] + args, models: URL(fileURLWithPath: defaultModels, isDirectory: true))
Log.shared.info("start", ["command": .s(cmd), "log_text": .b(Log.shared.withText)])
defer {
    let rss = peakRSSMB()
    Log.shared.info("end", ["command": .s(cmd), "seconds": .d((Date().timeIntervalSince(startedAt) * 1000).rounded() / 1000),
                            "peak_rss_mb": .d(rss.own), "peak_rss_children_mb": .d(rss.children)])
}
do {
    switch cmd {
    case "vlm-fuse":
        guard let path = args.first, let dir = option(args, "--vlm-dir"), let out = option(args, "--out") else { fail(usage) }
        var doc = try JSONDecoder().decode(FusedDoc.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        var reports: [[String: Any]] = []
        for i in doc.pages.indices {
            let f = URL(fileURLWithPath: dir).appendingPathComponent(String(format: "p%04d.txt", doc.pages[i].page))
            guard let t = try? String(contentsOf: f, encoding: .utf8) else { continue }
            let (p, r) = applyVLM(doc.pages[i], vlm: t)
            doc.pages[i] = p
            reports.append(["page": r.page, "skipped_no_ink": r.skippedNoInk, "raw_chars": r.gate.rawChars, "kept_chars": r.gate.keptChars,
                            "truncated": r.gate.truncatedByLength, "loop_cut": r.gate.loopCut, "flips": r.flips.count, "orphans": r.orphans.count,
                            "orphan_chars": r.orphans.map(\.unicodeScalars.count).reduce(0, +)])
            Log.shared.debug("vlm_page", ["page": .i(r.page), "raw_chars": .i(r.gate.rawChars), "kept_chars": .i(r.gate.keptChars),
                                          "truncated": .b(r.gate.truncatedByLength), "loop_cut": .b(r.gate.loopCut), "flips": .i(r.flips.count),
                                          "orphans": .i(r.orphans.count), "skipped_no_ink": .b(r.skippedNoInk)])
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(doc).write(to: URL(fileURLWithPath: out))
        if let rp = option(args, "--report") {
            try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: rp))
        }
        print("页 \(reports.count)  翻转 \(reports.map { $0["flips"] as! Int }.reduce(0, +))  VLM 独有片段 \(reports.map { $0["orphans"] as! Int }.reduce(0, +))")

    case "vl":
        // 进程内 PaddleOCR-VL：一批页图 → 文字，只用于对拍和度量
        guard let dir = option(args, "--vl-model"), let out = option(args, "--out") else { fail(usage) }
        let t0 = Date()
        let vl = try PaddleVL(directory: URL(fileURLWithPath: dir, isDirectory: true))
        var res: [String: String] = [:], secs: [Double] = []
        var i = 0
        while i < args.count {
            if ["--vl-model", "--out"].contains(args[i]) { i += 2; continue }
            let p = args[i]
            i += 1
            let img = try VisionEngine.loadImage(URL(fileURLWithPath: p))
            let (px, w, h) = try grayPixels(img)
            let t1 = Date()
            let r = vl.read(px, w: w, h: h)
            secs.append(Date().timeIntervalSince(t1))
            res[p] = r.text
            warn("\((p as NSString).lastPathComponent): \(r.tokens) tokens \(String(format: "%.1f", secs.last!))s")
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(res).write(to: URL(fileURLWithPath: out))
        print(String(format: "总 %.1fs  加载 %.2fs  均值 %.2fs/页  峰值内存 %.0f MB", Date().timeIntervalSince(t0), vl.loadSeconds,
                     secs.reduce(0, +) / Double(max(1, secs.count)), peakRSSMB().own))

    case "provider":
        try runProvider(args)

    case "verify-uploads":
        guard args.count >= 2 else { fail(usage) }
        let bad = reconcileUploads(report: try String(contentsOfFile: args[0], encoding: .utf8), rows: try FileLedger.rows(URL(fileURLWithPath: args[1])))
        for b in bad { print("✗ \(b)") }
        if !bad.isEmpty { exit(1) }
        print("✓ 报告与上传记录一致")

    case "history":
        try runHistory(args)

    case "adjudicate":
        try runAdjudicate(args)

    case "models":
        guard args.first == "fetch" else { fail(usage) }
        let dir = URL(fileURLWithPath: defaultModels, isDirectory: true)
        if args.contains("--vl") {
            let vl = VLModel.directory(models: dir)
            try ModelStore.fetchVL(base: option(args, "--url"), into: vl, log: warn)
            print("-> \(vl.path)")
            break
        }
        try ModelStore.fetch(url: option(args, "--url"), sha: option(args, "--sha256"), into: dir, log: warn)
        print("-> \(dir.path)")

    case "doctor":
        let checks = runDoctor(models: URL(fileURLWithPath: defaultModels, isDirectory: true),
                               outdir: URL(fileURLWithPath: option(args, "--outdir") ?? "output", isDirectory: true))
        for c in checks { print("\(c.ok ? "✓" : (c.required ? "✗" : "△")) \(c.name): \(c.detail)") }
        if let o = option(args, "--out") {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try enc.encode(checks).write(to: URL(fileURLWithPath: o))
        }
        if checks.contains(where: { !$0.ok && $0.required }) { exit(1) }

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
        let fixed = option(args, "--dpi").flatMap(Double.init)      // 不给就逐页按内嵌图分辨率定
        let doc = try PageRenderer.open(URL(fileURLWithPath: path))
        var result = EngineDoc(source: path, engine: "vision", dpi: fixed ?? RenderDefaults.baseDPI)
        var dpis = Set<Double>()
        for n in pageRange(option(args, "--pages"), count: doc.pageCount) {
            guard let page = doc.page(at: n - 1) else { fail("no page \(n)", code: 1) }
            let dpi = fixed ?? PageInspect.chooseDPI(page)
            dpis.insert(dpi)
            let r = try PageRenderer.render(doc, page: n, dpi: dpi)
            let native = PageInspect.hasNativeText(page)
            var p = PageDoc(page: n, width: r.image.width, height: r.image.height,
                            pdfWidth: r.pdfWidth, pdfHeight: r.pdfHeight, zoom: pyRound(r.zoom, 6),
                            rotation: r.rotation, nativeText: native)
            // 白页闸门：没墨迹就别让引擎读（VLM 在白页上会编造）。有文字层的不能当空白吞掉。
            let dark = PageInspect.darkRatio(r.image)
            if dark >= 0, dark < RenderDefaults.noInkDark {
                p.noInk = true
                if native {
                    p.lines = sortReadingOrder(PageInspect.nativeLines(page, zoom: r.zoom, visualHeight: r.pdfHeight))
                    p.textSource = "native_text"
                    warn("⚠ 第 \(n) 页无墨迹但有原生文字层: 已改用文字层 \(p.lines.count) 行, 这不是识别结果, 请复核")
                } else {
                    warn("⚠ 第 \(n) 页无墨迹且无文字层: 按白页处理")
                }
            } else {
                p.lines = sortReadingOrder(try VisionEngine.recognize(r.image))
            }
            result.pages.append(p)
            warn("page \(n): \(p.lines.count) lines  dpi \(dpi)")
        }
        if dpis.count == 1, let d = dpis.first { result.dpi = d }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(result).write(to: URL(fileURLWithPath: out))

    case "page-info":
        guard let path = args.first, let out = option(args, "--out") else { fail(usage) }
        let doc = try PageRenderer.open(URL(fileURLWithPath: path))
        var rows: [[String: Double]] = []
        for n in pageRange(option(args, "--pages"), count: doc.pageCount) {
            guard let page = doc.page(at: n - 1) else { fail("no page \(n)", code: 1) }
            let dpi = PageInspect.chooseDPI(page)
            let r = try PageRenderer.render(doc, page: n, dpi: args.contains("--ink") ? dpi : 18)
            let zoom = dpi / 72
            var row: [String: Double] = [
                "page": Double(n), "dpi": dpi, "zoom": pyRound(zoom, 6),
                "width": (r.pdfWidth * zoom - 0.001).rounded(.up), "height": (r.pdfHeight * zoom - 0.001).rounded(.up),
                "pdf_width": r.pdfWidth, "pdf_height": r.pdfHeight,
                "native_chars": Double(codePointCount(pyStrip(page.string ?? ""))),
            ]
            if args.contains("--ink") { row["dark"] = PageInspect.darkRatio(r.image) }
            rows.append(row)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(rows).write(to: URL(fileURLWithPath: out))

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
        o.useVLMBreaks = args.contains("--vlm-breaks")
        let (md, st) = toMarkdown(doc, options: o)
        try withMark(md).write(to: URL(fileURLWithPath: out), atomically: true, encoding: .utf8)
        if let sp = option(args, "--stats") {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try enc.encode(st).write(to: URL(fileURLWithPath: sp))
        }
        print("页 \(st.pages)  原始行 \(st.linesIn)  合行后 \(st.rows)  正文行 \(st.keptRows)  "
              + "丢弃 \(st.dropped)  标题 \(st.headings)  段落 \(st.paragraphs)  正文 \(st.chars) 字")

    case "pdf":
        guard args.count >= 2, let out = option(args, "--out") else { fail(usage) }
        let srcURL = URL(fileURLWithPath: args[0]), outURL = URL(fileURLWithPath: out)
        if srcURL.standardizedFileURL == outURL.standardizedFileURL { fail("输出路径不能等于源 PDF", code: 1) }
        if FileManager.default.fileExists(atPath: out), !args.contains("--force") {
            fail("输出已存在, 拒绝覆盖: \(out)（要覆盖请加 --force）", code: 3)
        }
        var o = PDFOutOptions()
        o.forceText = args.contains("--force-text")
        let st = try writeSearchablePDF(src: srcURL, fused: JSONDecoder().decode(FusedDoc.self, from: Data(contentsOf: URL(fileURLWithPath: args[1]))),
                                        out: outURL, options: o)
        if let sp = option(args, "--stats") {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try enc.encode(st).write(to: URL(fileURLWithPath: sp))
        }
        print("嵌字 \(st.pagesEmbedded)/\(st.pages) 页  行 \(st.linesWritten)  取回率 \(st.retrieval.map { "\($0)" } ?? "无")"
              + "  行级 \(st.lineRetrieval.map { "\($0)" } ?? "无")  \(st.sizeIn) → \(st.sizeOut)")
        for w in st.warnings.prefix(12) { warn("⚠ \(w)") }

    case "book":
        guard let path = args.first else { fail(usage) }
        var o = BookOptions(pdf: URL(fileURLWithPath: path).standardizedFileURL,
                            outdir: URL(fileURLWithPath: option(args, "--outdir") ?? "output", isDirectory: true),
                            workdir: URL(fileURLWithPath: option(args, "--workdir") ?? "work", isDirectory: true),
                            python: option(args, "--python") ?? ".venv/bin/python")
        o.md = !args.contains("--no-md")
        o.searchable = !args.contains("--no-pdf")
        o.pageMarks = option(args, "--page-marks") ?? "comment"
        o.vlmBreaks = args.contains("--vlm-breaks")
        o.pagesSpec = option(args, "--pages")
        o.vlmAll = args.contains("--vlm-all")
        guard ["none", "comment", "rule"].contains(o.pageMarks) else { fail(usage) }
        o.force = args.contains("--force")
        o.clobber = args.contains("--clobber")
        o.forceOCR = args.contains("--force-ocr")
        o.keepPages = args.contains("--keep-pages")
        if (option(args, "--paddle") ?? "coreml") == "coreml" {
            let dir = defaultModels
            guard FileManager.default.fileExists(atPath: dir + "/keys.txt") else {
                fail("找不到 Core ML 模型: \(dir)（先跑 ocr-cli models fetch，或用 --models-dir 指定）", code: 2)
            }
            o.coreml = URL(fileURLWithPath: dir, isDirectory: true)
            guard let u = computeUnits(option(args, "--units") ?? "ane") else { fail(usage) }
            o.units = u
            o.unitsLabel = option(args, "--units") ?? "ane"
        }
        if let v = option(args, "--vlm-url") {
            guard let u = URL(string: v), (try? Endpoint(v))?.isLoopback == true else {
                fail("--vlm-url 只接受本机地址: 默认不外传用户文件", code: 2)
            }
            o.vlmURL = u
            o.vlmModel = option(args, "--vlm-model") ?? "local"
        }
        if let id = option(args, "--vlm-provider") {
            guard !args.contains("--vlm"), option(args, "--vlm-url") == nil else { fail("--vlm-provider 不能和 --vlm / --vlm-url 同用", code: 2) }
            try prepareOnlineVLM(id, into: &o, args: args)
        }
        if args.contains("--vlm") {
            let dir = option(args, "--vl-model") ?? VLModel.directory(models: URL(fileURLWithPath: defaultModels, isDirectory: true)).path
            do {
                let vl = try PaddleVL(directory: URL(fileURLWithPath: dir, isDirectory: true))
                Log.shared.info("vlm_loaded", ["model": .s(dir), "seconds": .d((vl.loadSeconds * 1000).rounded() / 1000), "runtime": .s("mlx-swift")])
                o.vlmLocal = { px, w, h in vl.read(px, w: w, h: h).text }
            } catch {
                fail("\(error)（先跑 ocr-cli models fetch --vl，或用 --vl-model 指定，或 --vlm-url 走本地服务）", code: 2)
            }
        }
        do {
            let res = try runBook(o, log: warn)
            if let rp = option(args, "--result") {
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try enc.encode(res).write(to: URL(fileURLWithPath: rp))
            }
            print(String(format: "完成 %d 页  %.1fs (%.3fs/页)  峰值内存 %.0f / 子进程 %.0f MB",
                         res.pages, res.totalSeconds, res.secPerPage, res.peakRSSSelfMB, res.peakRSSChildrenMB))
            for f in res.outputs { print("-> \(f)") }
            if !res.degraded.isEmpty {
                for d in res.degraded { warn("⚠ 已降级: \(d)") }
                exit(3)
            }
        } catch let e as BookError {
            Log.shared.error("refused", ["command": .s(cmd), "error": .s("\(e)")])
            fail("\(e)", code: 3)
        }

    case "paddle-plan":
        guard let dir = option(args, "--models"), let out = option(args, "--out") else { fail(usage) }
        let e = try PaddleEngine(directory: URL(fileURLWithPath: dir, isDirectory: true), units: .all)
        let items = try e.allCompiled()
        nonisolated(unsafe) var plans: [DevicePlan] = []
        nonisolated(unsafe) var failure: Error?
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                for (name, url) in items {
                    for (label, u) in [("ane", MLComputeUnits.cpuAndNeuralEngine), ("all", .all)] {
                        if #available(macOS 14.4, *) {
                            plans.append(try await computePlan(url, name: name, units: u, label: label))
                        }
                    }
                }
            } catch { failure = error }
            sem.signal()
        }
        sem.wait()
        if let failure { throw failure }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(plans).write(to: URL(fileURLWithPath: out))

    case "paddle":
        guard let dir = option(args, "--models"), let out = option(args, "--out") else { fail(usage) }
        let units: [String: MLComputeUnits] = ["ane": .cpuAndNeuralEngine, "all": .all, "cpu": .cpuOnly, "gpu": .cpuAndGPU]
        guard let u = units[option(args, "--units") ?? "all"] else { fail(usage) }
        let skip = ["--models", "--units", "--out", "--batch"]
        var images: [String] = [], i = 0
        while i < args.count {
            if skip.contains(args[i]) { i += 2; continue }
            if args[i] != "--cls", args[i] != "--no-orient" { images.append(args[i]) }
            i += 1
        }
        let t0 = Date()
        let e = try PaddleEngine(directory: URL(fileURLWithPath: dir, isDirectory: true), units: u)
        e.useCls = args.contains("--cls")
        e.useOrientation = !args.contains("--no-orient")
        if let b = option(args, "--batch").flatMap(Int.init) { e.batchSize = b }
        var res: [String: [Line]] = [:]
        var seconds: [Double] = []
        for p in images {
            let img = try VisionEngine.loadImage(URL(fileURLWithPath: p))
            let t1 = Date()
            res[p] = try e.recognize(img)
            seconds.append(Date().timeIntervalSince(t1))
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(res).write(to: URL(fileURLWithPath: out))
        print(String(format: "总 %.1fs  载入 %.1fs  首页 %.2fs  其余均值 %.2fs/页 | det %.2f post %.2f crop %.2f cls %.2f rec %.2f",
                     Date().timeIntervalSince(t0), e.loadSeconds, seconds.first ?? 0,
                     seconds.count > 1 ? seconds.dropFirst().reduce(0, +) / Double(seconds.count - 1) : 0,
                     e.timing.det, e.timing.post, e.timing.crop, e.timing.cls, e.timing.rec))
        print("flex_pages \(e.flexPages) canvas_pages \(e.canvasFallbacks) tiled_pages \(e.tiledPages)")

    default:
        fail(usage)
    }
} catch {
    Log.shared.error("failed", ["command": .s(cmd), "type": .s("\(type(of: error))"), "error": .s("\(error)")])
    fail("\(error)", code: 1)
}
#else
fail("ocr-cli needs macOS (Vision / PDFKit)")
#endif
