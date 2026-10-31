#if canImport(PDFKit)
import CoreGraphics
import CoreML
import Foundation
import OCRCore
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

    public init(pdf: URL, outdir: URL, workdir: URL, python: String) {
        self.pdf = pdf; self.outdir = outdir; self.workdir = workdir; self.python = python
    }
}

public struct BookResult: Encodable {
    public var seconds: [String: Double] = [:]
    public var totalSeconds = 0.0, secPerPage = 0.0
    public var peakRSSSelfMB = 0.0, peakRSSChildrenMB = 0.0
    public var pages = 0, degraded: [String] = []
    public var outputs: [String] = []

    enum CodingKeys: String, CodingKey {
        case seconds, pages, degraded, outputs
        case totalSeconds = "total_seconds", secPerPage = "sec_per_page"
        case peakRSSSelfMB = "peak_rss_self_mb", peakRSSChildrenMB = "peak_rss_children_mb"
    }
}

public enum BookError: Error, CustomStringConvertible {
    case refused(String), failed(String)

    public var description: String {
        switch self {
        case .refused(let s), .failed(let s): return s
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
    let n = doc.pageCount
    var degraded: [String] = []

    // ---- 渲染 + 白页闸门 + Vision：分批，渲染串行（PDFDocument 不保证线程安全），Vision 和存图并行 ----
    final class Slot: @unchecked Sendable {
        var doc: PageDoc?
        var png: URL?
        var failed = false
        var error: String?
        var image: CGImage?
        var paddle: [Line] = []
        var dpi = 0.0, dark = 0.0, visionSec = 0.0, paddleSec = 0.0
        var gate = "ocr"
    }
    var slots: [Slot] = []
    var paddleFailed: [Int] = []
    var paddleSeconds = 0.0
    let paddle: PaddleEngine? = try o.coreml.map { try PaddleEngine(directory: $0, units: o.units) }
    if let paddle { logComputePlan(paddle, units: o.units, label: o.unitsLabel) }
    var dpis = Set<Double>()
    try stage("render+vision") {
        for start in stride(from: 1, through: n, by: o.jobs) {
            var batch: [(Int, Slot)] = []
            for pno in start...min(n, start + o.jobs - 1) {
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
            DispatchQueue.concurrentPerform(iterations: work.count) { i in
                let (pno, s) = work[i]
                autoreleasepool {
                    let tv = Date()
                    do {
                        s.doc!.lines = sortReadingOrder(try VisionEngine.recognize(s.image!))
                    } catch {
                        s.failed = true
                        s.error = "\(error)"
                        Log.shared.error("engine_failed", ["page": .i(pno), "engine": .s("vision"), "stage": .s("recognize"), "error": .s("\(error)")])
                    }
                    s.visionSec = Date().timeIntervalSince(tv)
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
            if let paddle {
                let t0 = Date()
                for (pno, s) in work {
                    let tp = Date()
                    do {
                        s.paddle = try paddle.recognize(s.image!)
                    } catch {
                        paddleFailed.append(pno)
                        log("⚠ 第 \(pno) 页 PP-OCR 失败: \(error)")
                        Log.shared.error("engine_failed", ["page": .i(pno), "engine": .s("ppocr"), "stage": .s("recognize"), "error": .s("\(error)")])
                    }
                    s.paddleSec = Date().timeIntervalSince(tp)
                    s.image = nil
                }
                paddleSeconds += Date().timeIntervalSince(t0)
            }
            if start % (o.jobs * 10) == 1 { log("渲染+Vision \(min(n, start + o.jobs - 1))/\(n)") }
        }
    }
    var vDoc = EngineDoc(source: o.pdf.path, engine: "vision", dpi: dpis.count == 1 ? dpis.first! : RenderDefaults.baseDPI,
                         pages: slots.map { $0.doc! })
    let visionFailed = slots.enumerated().filter(\.element.failed).map { $0.offset + 1 }

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
    } else {
      try stage("rapidocr") {
        let manifest = slots.enumerated().compactMap { (i, s) -> [String: String]? in
            s.png.map { ["page": "\(i + 1)", "png": $0.path] }
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
    let fused = try stage("fuse") { try fuse(vDoc, rDoc, log: flog) }
    try encodeJSON(fused).write(to: fURL)
    if Log.shared.enabled {
        let drops = Dictionary(grouping: flog.drops, by: \.page)
        for (i, s) in slots.enumerated() {
            let pno = i + 1
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
        try stage("md") {
            var opt = MDOptions()
            opt.pageMarks = o.pageMarks != "none"
            opt.pageRule = o.pageMarks == "rule"
            let (md, st) = toMarkdown(try JSONDecoder().decode(MDDoc.self, from: Data(contentsOf: fURL)), options: opt)
            mdStats = st
            Log.shared.info("md", ["paragraphs": .i(st.paragraphs), "headings": .i(st.headings), "chars": .i(st.chars),
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
    ri.srcPages = n
    try buildReport(ri).write(to: reportURL, atomically: true, encoding: .utf8)
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
