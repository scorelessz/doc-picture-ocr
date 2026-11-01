#if canImport(PDFKit)
import CoreGraphics
import CoreML
import Foundation
import ImageIO
import OCRCore
import OCRProviders
import PDFKit

// 总流程：渲染 → Vision + RapidOCR → 融合 → md / 可搜索 PDF / 报告。
// PP-OCR 默认走 Core ML（PaddleEngine），src/rapid_pages.py 只留作对照。
// 规矩与 run_books 相同：已存在就拒绝写；--force 只覆盖带本线归属标记的产物，别人的文件还要 --clobber。

public struct BookOptions {
    public var pdf: URL
    public var outdir: URL
    public var workdir: URL
    public var python: String
    public var md = true, searchable = true
    public var pageMarks = "comment"          // none | comment | rule
    public var force = false, clobber = false, forceOCR = false, keepPages = false
    public var jobs = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
    /// PP-OCR 用哪条路：Core ML 模型目录；为 nil 时走 src/rapid_pages.py（只留作对照）
    public var coreml: URL?
    public var units: MLComputeUnits = .cpuAndNeuralEngine
    public var unitsLabel = "ane"
    /// 本地 VLM（OpenAI 兼容接口）。只接受本机地址：默认不外传用户文件。
    public var vlmURL: URL?
    public var vlmModel = "local"
    /// 进程内 VLM：灰度像素 → 文字。设了就优先于 vlmURL。
    public var vlmLocal: (([UInt8], Int, Int) -> String)?
    /// 在线读字：一批页码 → 文字，并发在里面做，第二个参数报告已完成的页数。出错只影响那一页，保留本地结果。
    public var vlmOnlineBatch: (([Int], @escaping @Sendable (Int) -> Void) -> [Int: Result<String, Error>])?
    public var uploadsPath: URL?
    public var uploadBodies: URL?
    /// 在线裁决：融合之后、写产物之前调用，改过的读法才进得了 md 和 PDF。返回 nil 表示不用裁决。
    public var adjudicate: ((FusedDoc) throws -> (FusedDoc, AdjudicationSummary)?)?
    public var vlmBreaks = false
    /// 只处理这些页：A-B 或 a,b,c。nil 表示全部
    public var pagesSpec: String?
    /// 进度：阶段名、已完成、总数。在工作线程上回调。
    public var progress: (@Sendable (BookStage, Int, Int) -> Void)?
    /// 轮询取消。在每批页面、每页 VLM 之间检查。
    public var isCancelled: (@Sendable () -> Bool)?
    /// 默认只读有分歧行的页（别的页 VLM 翻转不了）；true 时每页都读，报告才有全书的独有片段
    public var vlmAll = false

    public init(pdf: URL, outdir: URL, workdir: URL, python: String) {
        self.pdf = pdf; self.outdir = outdir; self.workdir = workdir; self.python = python
    }
}

public enum BookStage: String, Sendable {
    case ocr = "识别", vlm = "读字", fuse = "融合", adjudicate = "在线裁决", markdown = "写 Markdown", pdf = "写 PDF", report = "写报告"
}

public struct BookResult: Encodable {
    public var seconds: [String: Double] = [:]
    public var totalSeconds = 0.0, secPerPage = 0.0
    public var peakRSSSelfMB = 0.0, peakRSSChildrenMB = 0.0
    public var pages = 0, degraded: [String] = []
    public var outputs: [String] = []
    public var adjudication: AdjudicationSummary?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case seconds, pages, degraded, outputs, adjudication
        case totalSeconds = "total_seconds", secPerPage = "sec_per_page"
        case peakRSSSelfMB = "peak_rss_self_mb", peakRSSChildrenMB = "peak_rss_children_mb"
    }
}

public enum BookError: Error, CustomStringConvertible {
    case refused(String), failed(String), cancelled

    public var description: String {
        switch self {
        case .refused(let s), .failed(let s): return s
        case .cancelled: return "已取消"
        }
    }
}

private func isMine(_ url: URL) -> Bool {
    if url.pathExtension == "md" {
        guard let h = try? FileHandle(forReadingFrom: url), let d = try? h.read(upToCount: 64) else { return false }
        return String(decoding: d, as: UTF8.self).hasPrefix(mdMark)
    }
    if url.pathExtension == "pdf" {
        return (PDFDocument(url: url)?.documentAttributes?[PDFDocumentAttribute.producerAttribute] as? String) == pdfProducer
    }
    return false
}

private func encodeJSON<T: Encodable>(_ v: T) throws -> Data {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try enc.encode(v)
}

private func peakRSS(_ who: Int32) -> Double {
    var u = rusage()
    getrusage(who, &u)
    return Double(u.ru_maxrss) / 1_048_576     // macOS 单位是字节
}

public func runBook(_ o: BookOptions, log: (String) -> Void) throws -> BookResult {
    let fm = FileManager.default
    let stem = o.pdf.deletingPathExtension().lastPathComponent
    let mdURL = o.outdir.appendingPathComponent("\(stem).md")
    let pdfURL = o.outdir.appendingPathComponent("\(stem).searchable.pdf")
    let reportURL = o.outdir.appendingPathComponent("\(stem).report.md")
    let vURL = o.workdir.appendingPathComponent("\(stem).vision.json")
    let rURL = o.workdir.appendingPathComponent("\(stem).rapidocr.json")
    let fURL = o.workdir.appendingPathComponent("\(stem).fused.json")
    let pagesDir = o.workdir.appendingPathComponent("\(stem).pages", isDirectory: true)

    var targets = [reportURL, vURL, rURL, fURL]
    if o.md { targets.append(mdURL) }
    if o.searchable { targets.append(pdfURL) }
    let existing = targets.filter { fm.fileExists(atPath: $0.path) }
    if !existing.isEmpty, !o.force {
        throw BookError.refused("产物已存在, 拒绝覆盖（要覆盖请加 --force）:\n" + existing.map { "  \($0.path)" }.joined(separator: "\n"))
    }
    let foreign = existing.filter { [mdURL, pdfURL].contains($0) && !isMine($0) }   // 报告和中间文件没有标记
    if !foreign.isEmpty, !o.clobber {
        throw BookError.refused("这些文件没有本线的归属标记, --force 不覆盖（确认要覆盖请加 --clobber）:\n"
                                + foreign.map { "  \($0.path)" }.joined(separator: "\n"))
    }
    try fm.createDirectory(at: o.outdir, withIntermediateDirectories: true)
    try fm.createDirectory(at: pagesDir, withIntermediateDirectories: true)

    var res = BookResult()
    var timing: [(String, Double)] = []
    func stage<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let t0 = Date()
        let v = try body()
        let dt = Date().timeIntervalSince(t0)
        timing.append((name, dt))
        res.seconds[name] = (dt * 100).rounded() / 100
        let rss = peakRSSMB()
        Log.shared.info("stage", ["name": .s(name), "seconds": .d((dt * 1000).rounded() / 1000),
                                  "peak_rss_mb": .d(rss.own), "peak_rss_children_mb": .d(rss.children)])
        return v
    }

    let doc = try PageRenderer.open(o.pdf)
    let srcPages = doc.pageCount
    let list = try o.pagesSpec.map { try parsePages($0, count: srcPages) } ?? Array(1...max(1, srcPages))
    let n = srcPages == 0 ? 0 : list.count
    var degraded: [String] = []

    // ---- 渲染 + 白页闸门 + Vision：分批，渲染串行（PDFDocument 不保证线程安全），Vision 和存图并行 ----
    final class Slot: @unchecked Sendable {
        var pno = 0
        var doc: PageDoc?
        var png: URL?
        var failed = false
        var error: String?
        var image: CGImage?
        var paddle: [Line] = []
        var dpi = 0.0, dark = 0.0, visionSec = 0.0, paddleSec = 0.0
        var gate = "ocr"
        var rotation = 0
        var upright: CGImage?
    }
    var slots: [Slot] = []
    var paddleFailed: [Int] = []
    var paddleSeconds = 0.0
    let paddle: PaddleEngine? = try o.coreml.map { try PaddleEngine(directory: $0, units: o.units) }
    if let paddle { logComputePlan(paddle, units: o.units, label: o.unitsLabel) }
    var dpis = Set<Double>()
    try stage("render+vision") {
        for start in stride(from: 0, to: n, by: o.jobs) {
            if o.isCancelled?() == true { throw BookError.cancelled }
            o.progress?(.ocr, start, n)
            var batch: [(Int, Slot)] = []
            for pno in list[start..<min(n, start + o.jobs)] {
                guard let page = doc.page(at: pno - 1) else { throw BookError.failed("读不到第 \(pno) 页") }
                let dpi = PageInspect.chooseDPI(page)
                dpis.insert(dpi)
                let r = try PageRenderer.render(doc, page: pno, dpi: dpi)
                let native = PageInspect.hasNativeText(page)
                var p = PageDoc(page: pno, width: r.image.width, height: r.image.height,
                                pdfWidth: r.pdfWidth, pdfHeight: r.pdfHeight, zoom: pyRound(r.zoom, 6),
                                rotation: r.rotation, nativeText: false)
                let dark = PageInspect.darkRatio(r.image)
                let noInk = dark >= 0 && dark < RenderDefaults.noInkDark
                if noInk { p.noInk = true }
                let slot = Slot()
                slot.pno = pno
                slot.dpi = dpi
                slot.dark = dark
                if native, noInk || !o.forceOCR {
                    slot.gate = noInk ? "no_ink_native_text" : "native_text"
                    // 文字本来就在页上：用文字层，不做 OCR，也不重复嵌字
                    p.nativeText = true
                    p.textSource = "native_text"
                    p.lines = sortReadingOrder(PageInspect.nativeLines(page, zoom: r.zoom, visualHeight: r.pdfHeight))
                    if noInk { log("⚠ 第 \(pno) 页无墨迹但有文字层: 已改用文字层 \(p.lines.count) 行") }
                } else if noInk {
                    slot.gate = "no_ink_blank"
                    log("⚠ 第 \(pno) 页无墨迹且无文字层: 按白页处理")
                } else {
                    slot.image = r.image
                }
                slot.doc = p
                slots.append(slot)
                batch.append((pno, slot))
            }
            let work = batch.filter { $0.1.image != nil }
            // PP-OCR 先跑：整页方向要由它判，Vision 用转正后的图
            if let paddle {
                let t0 = Date()
                for (pno, s) in work {
                    let tp = Date()
                    do {
                        let r = try paddle.recognizeOriented(s.image!)
                        s.paddle = r.lines
                        s.rotation = r.rotation
                        if r.rotation != 0 {
                            s.doc!.pageRotation = r.rotation
                            s.upright = try paddle.rotatedImage(s.image!, r.rotation)
                            log("⚠ 第 \(pno) 页判定为转了方向: 已顺时针转 \(r.rotation)° 再识别")
                        }
                    } catch {
                        paddleFailed.append(pno)
                        log("⚠ 第 \(pno) 页 PP-OCR 失败: \(error)")
                        Log.shared.error("engine_failed", ["page": .i(pno), "engine": .s("ppocr"), "stage": .s("recognize"), "error": .s("\(error)")])
                    }
                    s.paddleSec = Date().timeIntervalSince(tp)
                }
                paddleSeconds += Date().timeIntervalSince(t0)
            }
            DispatchQueue.concurrentPerform(iterations: work.count) { i in
                let (pno, s) = work[i]
                autoreleasepool {
                    let tv = Date()
                    do {
                        var ls = try VisionEngine.recognize(s.upright ?? s.image!)
                        if s.rotation != 0 {
                            let (w, h) = (s.image!.width, s.image!.height)
                            ls = ls.map { rotateBack($0, s.rotation, w: w, h: h) }
                        }
                        s.doc!.lines = sortReadingOrder(ls)
                    } catch {
                        s.failed = true
                        s.error = "\(error)"
                        Log.shared.error("engine_failed", ["page": .i(pno), "engine": .s("vision"), "stage": .s("recognize"), "error": .s("\(error)")])
                    }
                    s.visionSec = Date().timeIntervalSince(tv)
                    s.upright = nil
                    if o.coreml != nil {
                        if o.keepPages {
                            do { try PageRenderer.writePNG(s.image!, to: pagesDir.appendingPathComponent(String(format: "p%04d.png", pno))) } catch { s.error = "\(error)" }
                        }
                        s.image = nil
                    }
                    if o.coreml == nil {
                        let png = pagesDir.appendingPathComponent(String(format: "p%04d.png", pno))
                        do {
                            try PageRenderer.writePNG(s.image!, to: png)
                            s.png = png
                        } catch {
                            s.error = "\(error)"
                        }
                        s.image = nil
                    }
                }
            }
            if start % (o.jobs * 10) == 0 { log("渲染+Vision \(min(n, start + o.jobs))/\(n)") }
        }
    }
    var vDoc = EngineDoc(source: o.pdf.path, engine: "vision", dpi: dpis.count == 1 ? dpis.first! : RenderDefaults.baseDPI,
                         pages: slots.map { $0.doc! })
    let visionFailed = slots.filter(\.failed).map(\.pno)

    // ---- RapidOCR ----
    var rDoc = EngineDoc(source: o.pdf.path, engine: "rapidocr", dpi: vDoc.dpi,
                         pages: vDoc.pages.map { var p = $0; p.lines = []; return p })
    var rapidFailed: [Int] = []
    if paddle != nil {
        for (i, s) in slots.enumerated() { rDoc.pages[i].lines = s.paddle }
        rapidFailed = paddleFailed
        timing[0].1 -= paddleSeconds
        timing.append(("ppocr-coreml", paddleSeconds))
        res.seconds["render+vision"] = (timing[0].1 * 100).rounded() / 100
        res.seconds["ppocr-coreml"] = (paddleSeconds * 100).rounded() / 100
        let rss = peakRSSMB()
        Log.shared.info("stage", ["name": .s("ppocr-coreml"), "seconds": .d((paddleSeconds * 1000).rounded() / 1000),
                                  "peak_rss_mb": .d(rss.own), "peak_rss_children_mb": .d(rss.children),
                                  "units": .s(o.unitsLabel), "load_seconds": .d((paddle!.loadSeconds * 1000).rounded() / 1000),
                                  "det": .d(paddle!.timing.det), "post": .d(paddle!.timing.post), "crop": .d(paddle!.timing.crop),
                                  "rec": .d(paddle!.timing.rec), "canvas_fallbacks": .i(paddle!.canvasFallbacks)])
    } else {
      try stage("rapidocr") {
        let manifest = slots.compactMap { s -> [String: String]? in
            s.png.map { ["page": "\(s.pno)", "png": $0.path] }
        }.map { d -> [String: AnyCodable] in ["page": .int(Int(d["page"]!)!), "png": .string(d["png"]!)] }
        let mf = o.workdir.appendingPathComponent("\(stem).rapid-manifest.json")
        let of = o.workdir.appendingPathComponent("\(stem).rapid-lines.json")
        try encodeJSON(manifest).write(to: mf)
        try? fm.removeItem(at: of)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: o.python)
        proc.arguments = ["src/rapid_pages.py", mf.path, of.path]
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            degraded.append("RapidOCR 没有启动(\(error)): 全书只有 Vision 一个引擎, 没有交叉验证")
            return
        }
        guard proc.terminationStatus == 0, let data = try? Data(contentsOf: of),
              let out = try? JSONDecoder().decode(RapidOut.self, from: data) else {
            degraded.append("RapidOCR 退出码 \(proc.terminationStatus): 全书只有 Vision 一个引擎, 没有交叉验证")
            return
        }
        rapidFailed = out.failed
        for i in rDoc.pages.indices { rDoc.pages[i].lines = out.lines["\(rDoc.pages[i].page)"] ?? [] }
        try? fm.removeItem(at: mf)
        try? fm.removeItem(at: of)
      }
    }
    if !o.keepPages { try? fm.removeItem(at: pagesDir) }
    try encodeJSON(vDoc).write(to: vURL)
    try encodeJSON(rDoc).write(to: rURL)
    vDoc.pages.removeAll(keepingCapacity: false)
    vDoc = try JSONDecoder().decode(EngineDoc.self, from: Data(contentsOf: vURL))

    // ---- 融合 ----
    let flog = FuseLog()
    o.progress?(.fuse, n, n)
    var fused = try stage("fuse") { try fuse(vDoc, rDoc, log: flog) }

    // ---- VLM 第三票 ----
    var vlmReports: [VLMPageReport] = []
    if o.vlmLocal != nil || o.vlmURL != nil || o.vlmOnlineBatch != nil {
        try stage("vlm") {
            let doc2 = try PageRenderer.open(o.pdf)
            let dpiOf = Dictionary(slots.map { ($0.pno, $0.dpi) }, uniquingKeysWith: { a, _ in a })
            // 在线的先并发读完，下面的循环按页号顺序取结果，融合逻辑和串行时完全一样
            var online: [Int: Result<String, Error>] = [:]
            if let f = o.vlmOnlineBatch {
                let need = fused.pages.filter { p in
                    p.noInk != true && p.textSource != "native_text" && (o.vlmAll || p.lines.contains { $0.flag == "divergent" })
                }.map(\.page)
                let progress = o.progress
                online = f(need) { progress?(.vlm, $0, need.count) }
            }
            for i in fused.pages.indices {
                if o.isCancelled?() == true { throw BookError.cancelled }
                if o.vlmOnlineBatch == nil { o.progress?(.vlm, i, fused.pages.count) }
                let pno = fused.pages[i].page
                if fused.pages[i].noInk == true || fused.pages[i].textSource == "native_text" {
                    let (p, r) = applyVLM(fused.pages[i], vlm: nil)
                    fused.pages[i] = p
                    vlmReports.append(r)
                    continue
                }
                if !o.vlmAll, !fused.pages[i].lines.contains(where: { $0.flag == "divergent" }) {
                    var (_, r) = applyVLM(fused.pages[i], vlm: nil)
                    r.skippedNoDivergence = true
                    vlmReports.append(r)
                    continue
                }
                let t0 = Date()
                do {
                    let text: String
                    if o.vlmOnlineBatch != nil {
                        guard let r = online[pno] else { throw OnlineError.emptyReply }
                        text = try r.get()      // 请求体在确认前就定好了，不在这里重新渲染
                    } else {
                        let r0 = try PageRenderer.render(doc2, page: pno, dpi: dpiOf[pno] ?? RenderDefaults.baseDPI)
                        var img = r0.image
                        if let rot = fused.pages[i].pageRotation, let p = paddle { img = try p.rotatedImage(img, rot) }
                        if let f = o.vlmLocal {
                            let (px, w, h) = try grayPixels(img)
                            text = f(px, w, h)
                        } else {
                            text = try vlmRead(img, url: o.vlmURL!, model: o.vlmModel)
                        }
                    }
                    let (p, r) = applyVLM(fused.pages[i], vlm: text)
                    fused.pages[i] = p
                    vlmReports.append(r)
                    Log.shared.debug("vlm_page", ["page": .i(pno), "seconds": .d((Date().timeIntervalSince(t0) * 1000).rounded() / 1000),
                                                  "raw_chars": .i(r.gate.rawChars), "kept_chars": .i(r.gate.keptChars),
                                                  "truncated": .b(r.gate.truncatedByLength), "loop_cut": .b(r.gate.loopCut),
                                                  "flips": .i(r.flips.count), "orphans": .i(r.orphans.count)])
                } catch {
                    degraded.append("第 \(pno) 页 VLM 失败: \(error)")
                    Log.shared.error("engine_failed", ["page": .i(pno), "engine": .s("vlm"), "stage": .s("request"), "error": .s("\(error)")])
                }
            }
            Log.shared.info("vlm", ["pages": .i(vlmReports.count), "called": .i(vlmReports.filter { $0.gate.rawChars > 0 }.count),
                                    "skipped_no_ink": .i(vlmReports.filter(\.skippedNoInk).count),
                                    "skipped_no_divergence": .i(vlmReports.filter(\.skippedNoDivergence).count),
                                    "flips": .i(vlmReports.map(\.flips.count).reduce(0, +)),
                                    "orphans": .i(vlmReports.map(\.orphans.count).reduce(0, +))])
        }
    }
    if let d = o.uploadBodies { try? fm.removeItem(at: d) }
    var adjudication: AdjudicationSummary?
    if let f = o.adjudicate {
        o.progress?(.adjudicate, 0, 0)     // 单位是分歧处，数量由挂钩自己报
        if let (d, a) = try stage("adjudicate", { try f(fused) }) {
            fused = d
            adjudication = a
            if a.failed > 0 { degraded.append("在线裁决 \(a.failed) 处失败或没有发送, 这些行保留本地读法") }
        }
        if o.isCancelled?() == true { throw BookError.cancelled }
    }
    try encodeJSON(fused).write(to: fURL)
    if Log.shared.enabled {
        let drops = Dictionary(grouping: flog.drops, by: \.page)
        for (i, s) in slots.enumerated() {
            let pno = s.pno
            let fp = fused.pages.first { $0.page == pno }
            var f: [String: LogValue] = [
                "page": .i(pno), "dpi": .d(s.dpi), "width": .i(s.doc?.width ?? 0), "height": .i(s.doc?.height ?? 0),
                "dark": .d((s.dark * 100000).rounded() / 100000), "gate": .s(s.gate),
                "vision_lines": .i(vDoc.pages[i].lines.count), "vision_seconds": .d((s.visionSec * 1000).rounded() / 1000),
                "ppocr_lines": .i(rDoc.pages[i].lines.count), "ppocr_seconds": .d((s.paddleSec * 1000).rounded() / 1000),
                "fused_lines": .i(fp?.lines.count ?? 0),
                "divergent": .i(fp?.lines.filter { $0.flag == "divergent" }.count ?? 0),
                "only_vision": .i(fp?.lines.filter { $0.src == "vision" }.count ?? 0),
                "only_ppocr": .i(fp?.lines.filter { $0.src == "rapidocr" }.count ?? 0),
                "page_rotation": .i(s.rotation),
                "dedup": .i(drops[pno]?.count ?? 0),
                "dedup_new_rule": .i(drops[pno]?.filter(\.newRuleOnly).count ?? 0),
            ]
            if Log.shared.withText {
                f["lines"] = .a((fp?.lines ?? []).map { .s($0.text) })
            }
            Log.shared.debug("page", f)
        }
    }

    // ---- Markdown ----
    var mdStats: MDStats?
    if o.md {
        o.progress?(.markdown, n, n)
        try stage("md") {
            var opt = MDOptions()
            opt.pageMarks = o.pageMarks != "none"
            opt.pageRule = o.pageMarks == "rule"
            opt.useVLMBreaks = o.vlmBreaks
            let (md, st) = toMarkdown(try JSONDecoder().decode(MDDoc.self, from: Data(contentsOf: fURL)), options: opt)
            mdStats = st
            Log.shared.info("md", ["paragraphs": .i(st.paragraphs), "headings": .i(st.headings), "chars": .i(st.chars),
                                   "vlm_break_overrides": .i(st.vlmBreakOverrides),
                                   "dropped": .o(st.droppedDetail.mapValues { .i($0) }),
                                   "vertical_pages": .a(st.verticalPages.map { .i($0) }),
                                   "two_column_pages": .a(st.twoColumnPages.map { .i($0) })])
            for d in st.droppedLines {
                var f: [String: LogValue] = ["page": .i(d.page), "reason": .s(d.reason)]
                if Log.shared.withText { f["text"] = .s(d.text) }
                Log.shared.debug("md_dropped", f)
            }
            let part = mdURL.deletingLastPathComponent().appendingPathComponent(mdURL.lastPathComponent + ".part")
            try withMark(md).write(to: part, atomically: false, encoding: .utf8)
            _ = try? fm.removeItem(at: mdURL)
            try fm.moveItem(at: part, to: mdURL)
        }
        res.outputs.append(mdURL.path)
    }

    // ---- 可搜索 PDF ----
    var rp: ReportPDF?
    if o.searchable {
        o.progress?(.pdf, n, n)
        let st = try stage("pdf") { try writeSearchablePDF(src: o.pdf, fused: fused, out: pdfURL) }
        var p = ReportPDF()
        p.retrieval = st.retrieval; p.lineRetrieval = st.lineRetrieval; p.worst = st.retrievalWorst
        p.worstPage = st.retrievalWorstPage; p.charsIn = st.charsIn; p.charsRetrieved = st.charsRetrieved
        p.pages = st.pages; p.embedded = st.pagesEmbedded; p.skippedNative = st.pagesSkippedNative
        p.skippedGate = st.pagesSkippedNativeGate; p.skippedNoJSON = st.pagesSkippedNoJSON
        p.skippedEmpty = st.pagesSkippedEmpty; p.linesWritten = st.linesWritten; p.linesDropped = st.linesDropped
        p.probeFound = st.probeFound; p.probeChecked = st.probeChecked; p.probeMean = st.probeMeanOffset
        p.probeMax = st.probeMaxOffset; p.sizeIn = st.sizeIn; p.sizeOut = st.sizeOut
        p.belowThreshold = st.pagesBelowThreshold; p.warnings = st.warnings
        rp = p
        Log.shared.info("pdf", ["embedded": .i(st.pagesEmbedded), "skipped_native": .i(st.pagesSkippedNative),
                                "skipped_gate": .i(st.pagesSkippedNativeGate), "retrieval": st.retrieval.map { .d($0) } ?? .null,
                                "line_retrieval": st.lineRetrieval.map { .d($0) } ?? .null,
                                "probe_found": .i(st.probeFound), "probe_checked": .i(st.probeChecked),
                                "size_in": .i(st.sizeIn), "size_out": .i(st.sizeOut)])
        for w in st.warnings { Log.shared.warn("pdf_warning", ["message": .s(w)]) }
        res.outputs.append(pdfURL.path)
    }

    // ---- 报告 ----
    o.progress?(.report, n, n)
    if !visionFailed.isEmpty { degraded.append("Vision 在第 \(visionFailed) 页失败") }
    if !rapidFailed.isEmpty { degraded.append("PP-OCR 在第 \(rapidFailed) 页失败") }
    if let paddle, paddle.canvasFallbacks > 0 {
        degraded.append("\(paddle.canvasFallbacks) 页没有尺寸正好的检测模型, 用大画布补白识别, 精度偏低: 用 tools/convert_paddle.py 转这个尺寸")
    }
    let bothFailed = Array(Set(visionFailed).intersection(rapidFailed)).sorted()
    let single = Array(Set(visionFailed).symmetricDifference(rapidFailed)).sorted()
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    var ri = ReportInput(source: o.pdf.path, sourceSize: (try? o.pdf.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0,
                         mdPath: o.md ? mdURL.path : nil, pdfPath: o.searchable ? pdfURL.path : nil, fusedPath: fURL.path,
                         generatedAt: df.string(from: Date()), dpi: vDoc.dpi, fused: fused, log: flog)
    ri.timing = timing
    ri.md = mdStats
    ri.pdf = rp
    ri.degraded = degraded
    ri.failedPages = bothFailed
    ri.singleEnginePages = single
    ri.srcPages = srcPages
    if o.pagesSpec != nil { ri.processedPages = list }
    ri.vlm = vlmReports
    ri.adjudication = adjudication
    res.adjudication = adjudication
    if let u = o.uploadsPath, let rows = try? FileLedger.rows(u) {
        let tf = ISO8601DateFormatter()
        ri.uploads = rows.map { UploadRow(time: tf.string(from: $0.time), host: $0.host, model: $0.model, page: $0.page, bytes: $0.bytes, status: $0.status) }
    }
    var report = buildReport(ri)
    if let u = o.uploadsPath, let rows = try? FileLedger.rows(u) {
        let bad = reconcileUploads(report: report, rows: rows)
        for b in bad {
            degraded.append("上传对账: \(b)")
            Log.shared.error("upload_mismatch", ["detail": .s(b)])
        }
        if !bad.isEmpty { report += "\n## 上传对账不一致\n\n" + bad.map { "- \($0)" }.joined(separator: "\n") + "\n" }
    }
    try report.write(to: reportURL, atomically: true, encoding: .utf8)
    res.outputs.append(reportURL.path)

    for d in degraded { Log.shared.warn("degraded", ["message": .s(d)]) }
    res.pages = n
    res.degraded = degraded
    res.totalSeconds = (timing.map(\.1).reduce(0, +) * 10).rounded() / 10
    res.secPerPage = pyRound(res.totalSeconds / Double(max(1, n)), 3)
    res.peakRSSSelfMB = (peakRSS(RUSAGE_SELF) * 10).rounded() / 10
    res.peakRSSChildrenMB = (peakRSS(RUSAGE_CHILDREN) * 10).rounded() / 10
    return res
}

/// 在线读字的一次任务：确认前算好请求体和清单，确认后接到 BookOptions。CLI 和 App 共用。
public struct OnlinePlan: Sendable {
    public let preset: ProviderPreset, endpoint: Endpoint, model: String
    public let pages: [OnlinePage], manifest: UploadManifest, bodies: URL

    public init(preset: ProviderPreset, endpoint: Endpoint, model: String, pages: [OnlinePage], manifest: UploadManifest, bodies: URL) {
        self.preset = preset; self.endpoint = endpoint; self.model = model
        self.pages = pages; self.manifest = manifest; self.bodies = bodies
    }

    public static func prepare(preset: ProviderPreset, model: String, pdf: URL, forceOCR: Bool, pagesSpec: String? = nil, workdir: URL, log: (String) -> Void) throws -> OnlinePlan {
        let endpoint = try Endpoint(preset.baseURL)
        let stem = pdf.deletingPathExtension().lastPathComponent
        let dir = workdir.appendingPathComponent("\(stem).upload", isDirectory: true)
        let pages = try prepareOnlinePages(pdf: pdf, model: model, maxEdge: 1792, forceOCR: forceOCR, pagesSpec: pagesSpec, into: dir, log: log)
        let m = onlineManifest(pages, providerID: preset.id, providerName: preset.name, host: endpoint.host, model: model)
        return OnlinePlan(preset: preset, endpoint: endpoint, model: model, pages: pages, manifest: m, bodies: dir)
    }

    /// 请求体里是页面图片，不确认就删
    public func discard() { try? FileManager.default.removeItem(at: bodies) }

    public func attach(to o: inout BookOptions, transport: HTTPTransport, key: SecretKey?, ticket: UploadTicket, jobs: Int = OnlineJobs.default) throws {
        let stem = o.pdf.deletingPathExtension().lastPathComponent
        let uploads = o.outdir.appendingPathComponent("\(stem).uploads.jsonl")
        try FileManager.default.createDirectory(at: o.outdir, withIntermediateDirectories: true)
        let reader = OnlineReader(transport: transport, endpoint: endpoint, providerID: preset.id, model: model, key: key,
                                  ticket: ticket, ledger: try FileLedger(uploads), jobs: jobs)
        let byPage = Dictionary(uniqueKeysWithValues: pages.map { ($0.page, $0) })
        o.uploadsPath = uploads
        o.uploadBodies = bodies
        let cancelled = o.isCancelled
        o.vlmOnlineBatch = { pnos, onDone in
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var out: [Int: Result<String, Error>] = [:]
            Task.detached {
                let list = pnos.compactMap { byPage[$0] }
                let rs: [Result<String, Error>?] = await runConcurrently(list, limiter: reader.limiter, shouldStop: { cancelled?() == true }, onDone: onDone) { p in
                    do { return .success(try await reader.read(p)) } catch { return .failure(error) }
                }
                for (p, r) in zip(list, rs) { if let r { out[p.page] = r } }
                sem.signal()
            }
            sem.wait()
            return out
        }
    }
}

/// 在线裁决的一次任务：确认前算好问题和清单。CLI 和 App 共用。
public struct AdjudicationPlan: Sendable {
    public let preset: ProviderPreset, endpoint: Endpoint, model: String, mode: AdjudicationMode
    public let questions: [AdjudicationQuestion], pages: [OnlinePage], manifest: UploadManifest, bodies: URL

    /// 候选文字的总字数
    public var chars: Int { questions.map { $0.candidates.map(\.count).reduce(0, +) }.reduce(0, +) }
    public var crops: Int { mode == .image ? questions.count : 0 }

    public static func build(doc: FusedDoc, source: String, preset: ProviderPreset, model: String, mode: AdjudicationMode, pages filter: Set<Int>? = nil,
                             bodies: URL, crop: (Int, FusedLine) throws -> Data?) throws -> AdjudicationPlan {
        let endpoint = try Endpoint(preset.baseURL)
        let qs = try adjudicationQuestions(doc, pages: filter, mode: mode, crop: crop)
        try FileManager.default.createDirectory(at: bodies, withIntermediateDirectories: true)
        let items = try qs.map { q -> OnlinePage in
            let b = try AdjudicationBody.make(model: model, q), f = bodies.appendingPathComponent(q.id + ".json")
            try b.write(to: f)
            return OnlinePage(id: q.id, sourceFile: source, page: q.page, body: f, bytes: b.count)
        }
        let m = onlineManifest(items, providerID: preset.id, providerName: preset.name, host: endpoint.host, model: model)
        return AdjudicationPlan(preset: preset, endpoint: endpoint, model: model, mode: mode, questions: qs, pages: items, manifest: m, bodies: bodies)
    }

    public static func prepare(doc: FusedDoc, pdf: URL?, source: String, preset: ProviderPreset, model: String, mode: AdjudicationMode,
                               pages: Set<Int>? = nil, bodies: URL) throws -> AdjudicationPlan {
        let cropper = try pdf.map { try LineCropper(pdf: $0, doc: doc) }
        return try build(doc: doc, source: source, preset: preset, model: model, mode: mode, pages: pages, bodies: bodies) { pno, l in
            try autoreleasepool { try cropper?.crop(page: pno, line: l) }     // 后台线程没有事件循环，不手动释放，整页图会一直堆着
        }
    }

    public func discard() { try? FileManager.default.removeItem(at: bodies) }

    public func run(_ doc: FusedDoc, reader: OnlineReader, isCancelled: @escaping @Sendable () -> Bool = { false },
                    onDone: @escaping @Sendable (Int) -> Void = { _ in }) async -> AdjudicationOutcome {
        await runAdjudication(doc, questions: questions, pages: pages, mode: mode, reader: reader, providerID: preset.id, model: model,
                              isCancelled: isCancelled, onDone: onDone)
    }

    public func summary(_ o: AdjudicationOutcome) -> AdjudicationSummary {
        o.summary(provider: preset.name, model: model, mode: mode, total: questions.count)
    }

    public func declinedSummary() -> AdjudicationSummary {
        var s = AdjudicationSummary(provider: preset.name, model: model, mode: mode.title)
        s.total = questions.count
        s.declined = true
        return s
    }
}

/// 把分歧行从页面图里裁出来。只有这一行，不含整页。
public final class LineCropper {
    private let doc: PDFDocument, zoom: [Int: Double]
    private var cached: (page: Int, image: CGImage)?       // 分歧行按页排列，一页十来处，不能每处都重新渲染

    public init(pdf: URL, doc fused: FusedDoc) throws {
        doc = try PageRenderer.open(pdf)
        zoom = Dictionary(fused.pages.map { ($0.page, $0.zoom) }, uniquingKeysWith: { a, _ in a })
    }

    public func crop(page: Int, line: FusedLine) throws -> Data {
        if cached?.page != page {
            cached = (page, try PageRenderer.render(doc, page: page, dpi: (zoom[page] ?? 300.0 / 72) * 72).image)
        }
        let image = cached!.image
        let c = lineCropRect(line, imageWidth: image.width, imageHeight: image.height)
        guard let img = image.cropping(to: CGRect(x: c.x, y: c.y, width: c.w, height: c.h)), let data = CFDataCreateMutable(nil, 0),
              let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw PaddleError.badImage }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw PaddleError.badImage }
        return data as Data
    }
}

/// 上传前的准备：渲染、缩放、编码成请求体落盘。跳过无墨迹页和用文字层的页。在做任何 OCR 之前调用。
public func prepareOnlinePages(pdf: URL, model: String, maxEdge: Int, forceOCR: Bool, pagesSpec: String? = nil, into dir: URL, log: (String) -> Void) throws -> [OnlinePage] {
    let doc = try PageRenderer.open(pdf)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var out: [OnlinePage] = []
    for pno in try pagesSpec.map({ try parsePages($0, count: doc.pageCount) }) ?? Array(1...max(1, doc.pageCount)) {
        guard let page = doc.page(at: pno - 1) else { continue }
        try autoreleasepool {
            let r = try PageRenderer.render(doc, page: pno, dpi: PageInspect.chooseDPI(page))
            let dark = PageInspect.darkRatio(r.image)
            if dark >= 0, dark < RenderDefaults.noInkDark { return }
            if PageInspect.hasNativeText(page), !forceOCR { return }
            let g = try Gray(r.image)
            let k = min(1, Double(maxEdge) / Double(max(g.w, g.h)))
            let small = k < 1 ? g.resized(Int(Double(g.w) * k), Int(Double(g.h) * k)) : g
            guard let cg = small.cgImage, let data = CFDataCreateMutable(nil, 0),
                  let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw PaddleError.badImage }
            CGImageDestinationAddImage(dest, cg, nil)
            guard CGImageDestinationFinalize(dest) else { throw PaddleError.badImage }
            let body = try ChatBody.make(model: model, png: data as Data)
            let f = dir.appendingPathComponent(String(format: "p%04d.json", pno))
            try body.write(to: f)
            out.append(OnlinePage(id: "p\(pno)", sourceFile: pdf.lastPathComponent, page: pno, body: f, bytes: body.count))
        }
        if pno % 50 == 0 { log("准备上传内容 \(pno)/\(doc.pageCount)") }
    }
    return out
}

/// 本地 OpenAI 兼容接口读一页。长边缩到 1792，提示词用 PaddleOCR-VL 的 "OCR:"。
func vlmRead(_ image: CGImage, url: URL, model: String) throws -> String {
    let g = try Gray(image)
    let k = min(1, 1792.0 / Double(max(g.w, g.h)))
    let small = k < 1 ? g.resized(Int(Double(g.w) * k), Int(Double(g.h) * k)) : g
    guard let cg = small.cgImage, let data = CFDataCreateMutable(nil, 0),
          let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw PaddleError.badImage }
    CGImageDestinationAddImage(dest, cg, nil)
    guard CGImageDestinationFinalize(dest) else { throw PaddleError.badImage }
    let b64 = (data as Data).base64EncodedString()
    let body: [String: Any] = ["model": model, "temperature": 0, "max_tokens": 4096, "messages": [["role": "user", "content": [
        ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(b64)"]], ["type": "text", "text": "OCR:"]]]]]
    let payload = try JSONSerialization.data(withJSONObject: body)
    let req = OutboundRequest(endpoint: try Endpoint(url.absoluteString), providerID: "local", path: "chat/completions", payload: .loopback(body: payload))
    let t = GuardedTransport(wire: URLSessionWire(), network: NetworkSwitch(), selection: ProviderSelection(), gate: UploadGate())
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var out: Result<String, Error> = .failure(BookError.failed("VLM 无响应"))
    Task.detached {
        defer { sem.signal() }
        do {
            let r = try await t.send(req)
            guard let j = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any],
                  let c = j["choices"] as? [[String: Any]], let m = c.first?["message"] as? [String: Any] else {
                out = .failure(BookError.failed("VLM 响应无法解析"))
                return
            }
            out = .success(m["content"] as? String ?? "")
        } catch { out = .failure(error) }
    }
    sem.wait()
    return try out.get()
}

private struct RapidOut: Decodable {
    var lines: [String: [Line]]
    var failed: [Int]
}

private enum AnyCodable: Encodable {
    case int(Int), string(String)

    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self {
        case .int(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        }
    }
}
#endif
