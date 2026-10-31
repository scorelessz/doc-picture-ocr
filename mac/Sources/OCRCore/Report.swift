import Foundation

// run_books.build_report 的移植：<名>.report.md，没有人工校对环节时用户唯一的质量抓手。
// 比 Python 版多两节：白页闸门、去重明细。

public struct ReportPDF: Sendable {
    public var retrieval: Double?, lineRetrieval: Double?, worst: Double?
    public var worstPage: Int?
    public var charsIn = 0, charsRetrieved = 0
    public var pages = 0, embedded = 0, skippedNative = 0, skippedGate = 0, skippedNoJSON = 0, skippedEmpty = 0
    public var linesWritten = 0, linesDropped = 0
    public var probeFound = 0, probeChecked = 0
    public var probeMean: Double?, probeMax: Double?
    public var sizeIn = 0, sizeOut = 0
    public var belowThreshold: [Int] = []
    public var warnings: [String] = []
    public var minRetrieval = 0.98
    public init() {}
}

public struct ReportInput: Sendable {
    public var source: String
    public var sourceSize: Int
    public var mdPath: String?, pdfPath: String?, fusedPath: String
    public var generatedAt: String
    public var dpi: Double
    public var timing: [(String, Double)] = []
    public var fused: FusedDoc
    public var log: FuseLog
    public var md: MDStats?
    public var pdf: ReportPDF?
    public var degraded: [String] = []
    public var failedPages: [Int] = []
    public var singleEnginePages: [Int] = []
    public var srcPages: Int?

    public init(source: String, sourceSize: Int, mdPath: String?, pdfPath: String?, fusedPath: String,
                generatedAt: String, dpi: Double, fused: FusedDoc, log: FuseLog) {
        self.source = source; self.sourceSize = sourceSize; self.mdPath = mdPath; self.pdfPath = pdfPath
        self.fusedPath = fusedPath; self.generatedAt = generatedAt; self.dpi = dpi; self.fused = fused; self.log = log
    }
}

private func human(_ n: Int) -> String {
    n >= 1 << 20 ? String(format: "%.2f MB", Double(n) / 1_048_576) : String(format: "%.0f KB", Double(n) / 1024)
}

private func cell(_ s: String, _ n: Int = 60) -> String {
    let t = s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    var v = String.UnicodeScalarView()
    v.append(contentsOf: t.unicodeScalars.prefix(n))
    return String(v)
}

private func pct(_ x: Double) -> String { String(format: "%.1f", x * 100) }

public func buildReport(_ r: ReportInput) -> String {
    var L: [String] = []
    var sec = 0
    func A(_ s: String = "") { L.append(s) }
    func H(_ t: String) {
        sec += 1
        A("## \(sec)　\(t)")
        A()
    }
    let f = r.fused, st = f.stats
    let npages = max(1, st.pages)
    let total = r.timing.map(\.1).reduce(0, +)
    let stem = ((r.source as NSString).lastPathComponent as NSString).deletingPathExtension

    A("# OCR 质量报告 · \(stem)")
    A()
    if !r.degraded.isEmpty {
        A("> ## ⚠ 本次运行**已降级**, 产物不可全信")
        A(">")
        for d in r.degraded { A("> - \(d)") }
        A(">")
        A("> 下面的取回率/分歧率都只统计**真的识别到了的内容**, 丢掉的页不进分母 —— 数字好看不代表这一本是完整的。")
        A()
    }
    A("- 源文件: `\(r.source)`  (\(human(r.sourceSize)))")
    if let p = r.mdPath { A("- Markdown: `\(p)`") }
    if let p = r.pdfPath { A("- 可搜索 PDF: `\(p)`") }
    A("- 融合数据: `\(r.fusedPath)`")
    A("- 生成时间: \(r.generatedAt)   引擎: vision, rapidocr   基准 dpi: \(String(format: "%g", r.dpi))")
    if total > 0 {
        A(String(format: "- 耗时: **%.1fs** (%.2fs/页) = ", total, total / Double(npages))
          + r.timing.map { String(format: "%@ %.2fs", $0.0, $0.1) }.joined(separator: " + "))
    }
    A()

    // ---- 识别 ----
    let divRate = Double(st.divergent) / Double(max(1, st.both))
    let singleRate = Double(st.onlyVision + st.onlyRapidocr) / Double(max(1, st.lines))
    let lowConf = f.pages.flatMap { p in p.lines.filter { $0.flag == "low_conf" }.map { (p.page, $0) } }
    let lowPages = Array(Set(lowConf.map(\.0))).sorted()
    var divByPage: [(Int, Int)] = []
    for p in f.pages {
        let n = p.lines.filter { $0.flag == "divergent" }.count
        if n > 0 { divByPage.append((p.page, n)) }
    }
    divByPage = stableSorted(divByPage) { $0.1 > $1.1 }
    let gateNative = f.pages.filter { $0.noInk == true && $0.textSource == "native_text" }.map(\.page)
    let gateBlank = f.pages.filter { $0.noInk == true && $0.textSource != "native_text" }.map(\.page)
    let nativeUsed = f.pages.filter { $0.noInk != true && $0.textSource == "native_text" }.map(\.page)
    let empty = f.pages.filter { $0.lines.isEmpty }.map(\.page)
    let newDrops = r.log.drops.filter(\.newRuleOnly)

    H("识别与融合")
    A("| 项 | 值 |")
    A("|---|---|")
    A("| 页数 | \(st.pages)" + (r.srcPages.map { $0 != st.pages ? " / 源 PDF \($0)" : "" } ?? "") + " |")
    A("| 文本行 | \(st.lines) |")
    A("| 双引擎都读到(配对行) | \(st.both) |")
    A("| 仅 Vision 读到 | \(st.onlyVision) |")
    A("| 仅 RapidOCR 读到 | \(st.onlyRapidocr) |")
    A("| 两引擎分歧(已自动裁决) | \(st.divergent)　占配对行 **\(pct(divRate))%** |")
    A("| 单源行占比 | **\(pct(singleRate))%** |")
    A("| 低可信行 | \(lowConf.count) |")
    A("| 丢弃的空检测框 | \(st.droppedEmpty) |")
    A("| 去重(并进配对行的单源读法) | \(st.droppedContained)，其中新规则才去掉的 \(newDrops.count) |")
    A("| OCR 失败页(内容缺失) | \(r.failedPages.isEmpty ? "无" : "\(r.failedPages)") |")
    A("| 只有单引擎读到的页 | \(r.singleEnginePages.isEmpty ? "无" : "\(r.singleEnginePages)") |")
    A("| 一行字都没有的页 | \(empty.isEmpty ? "无" : "\(empty)") |")
    A()
    if !r.failedPages.isEmpty {
        A("> ⚠ 第 \(r.failedPages.map(String.init).joined(separator: ", ")) 页识别时引擎崩了 —— 这些页在 Markdown 和文字层里是**缺的**, 不是「这页没字」。")
        A()
    }
    A("> 单源行 = 只有一个引擎读出来、没有第二份读法可对照的行, 是项目实测里残留错误最集中的地方。"
      + "分歧行已由打分规则自动裁出胜负, 败者保留在 `fused.json` 的 `alt` 字段里。")
    A()

    // ---- 白页闸门 ----
    H("白页闸门")
    if gateNative.isEmpty, gateBlank.isEmpty, nativeUsed.isEmpty {
        A("本次没有命中: 所有页的渲染图都有墨迹, 都走了 OCR。")
    } else {
        A("| 处理 | 页 |")
        A("|---|---|")
        A("| 无墨迹, 改用文字层 | \(gateNative.isEmpty ? "无" : "\(gateNative)") |")
        A("| 无墨迹, 无文字层, 按白页处理 | \(gateBlank.isEmpty ? "无" : "\(gateBlank)") |")
        A("| 有文字层, 未做 OCR | \(nativeUsed.isEmpty ? "无" : "\(nativeUsed)") |")
        A()
        if !gateNative.isEmpty {
            A("> ⚠ 第 \(gateNative.map(String.init).joined(separator: ", ")) 页**图上看不到字, 但 PDF 里有文字层**。"
              + "这些文字不是识别出来的, 来源和对错都没有图像依据, 请翻原件确认。")
        }
        if !gateBlank.isEmpty {
            A("> 第 \(gateBlank.map(String.init).joined(separator: ", ")) 页按白页处理, 没有跑 OCR。翻一下原件确认确实没有内容。")
        }
    }
    A()

    // ---- 优先复核 ----
    H("优先复核的页")
    var sus: [Int: [String]] = [:]
    for p in r.failedPages { sus[p, default: []].append("**OCR 失败(内容缺失)**") }
    for p in r.singleEnginePages { sus[p, default: []].append("只有单引擎读到(无交叉验证)") }
    for p in gateNative { sus[p, default: []].append("**无墨迹, 文字来自文字层**") }
    for p in empty where !gateBlank.contains(p) { sus[p, default: []].append("一行字都没有") }
    for (p, n) in divByPage.prefix(12) { sus[p, default: []].append("分歧 \(n) 行") }
    for p in lowPages { sus[p, default: []].append("有低可信行") }
    for p in r.pdf?.belowThreshold ?? [] { sus[p, default: []].append("嵌字取回偏低") }
    if sus.isEmpty {
        A("无 —— 没有分歧页、低可信行或取回率偏低的页。")
    } else {
        A("| 页 | 原因 |")
        A("|---|---|")
        for p in sus.keys.sorted().prefix(30) { A("| \(p) | \(sus[p]!.joined(separator: "、")) |") }
        if sus.count > 30 { A("| … | 另有 \(sus.count - 30) 页 |") }
    }
    A()
    if !lowConf.isEmpty {
        A("### 低可信行(最多 12 条)")
        A()
        A("| 页 | 来源 | conf | 文本 |")
        A("|---|---|---|---|")
        for (p, l) in lowConf.prefix(12) { A("| \(p) | \(l.src) | \(l.conf) | \(cell(l.text, 40)) |") }
        A()
    }
    if !r.log.arbitrations.isEmpty {
        A("### 自动裁决抽样(最多 8 条)")
        A()
        A("| 页 | 采用 | vision | rapidocr |")
        A("|---|---|---|---|")
        for d in r.log.arbitrations.prefix(8) { A("| \(d.page) | \(d.winner) | \(cell(d.vision, 24)) | \(cell(d.rapidocr, 24)) |") }
        A()
    }

    // ---- 去重 ----
    H("去重明细")
    if r.log.drops.isEmpty {
        A("本次没有单源读法被并进配对行。")
    } else {
        A("共 \(r.log.drops.count) 条, 新规则才去掉的 \(newDrops.count) 条。被去掉的读法保留在 `fused.json` 的 `alt` 里, 没有丢失。"
          + "注意保留的总是配对行, 被去掉的读法可能反而是对的, 按距离从大到小列出。")
        A()
        if !newDrops.isEmpty {
            A("| 页 | 来源 | 距离 | 被去掉 | 保留的行 |")
            A("|---|---|---|---|---|")
            for d in stableSorted(newDrops, by: { $0.distance > $1.distance }).prefix(60) {
                A("| \(d.page) | \(d.src) | \(d.distance) | \(cell(d.text)) | \(cell(d.kept)) |")
            }
            if newDrops.count > 60 { A("| … | | | 另有 \(newDrops.count - 60) 条 | |") }
        }
    }
    A()

    // ---- Markdown ----
    if let m = r.md {
        H("Markdown 版面")
        A("| 项 | 值 |")
        A("|---|---|")
        A("| 原始行 → 合行后 → 正文行 | \(m.linesIn) → \(m.rows) → \(m.keptRows) |")
        A("| 段落 / 标题 | \(m.paragraphs) / \(m.headings) |")
        A("| 正文字数 | \(m.chars) |")
        let det = m.droppedDetail.sorted { $0.key.unicodeScalars.lexicographicallyPrecedes($1.key.unicodeScalars) }
            .map { "\($0.key) \($0.value)" }.joined(separator: "、")
        A("| 丢弃 | \(m.dropped) 行: \(det.isEmpty ? "无" : det) |")
        A()
        if !m.verticalPages.isEmpty { A("> ⚠ 竖排页 \(m.verticalPages) —— 本版不支持竖排版面, 已按横排原样输出。"); A() }
        if !m.twoColumnPages.isEmpty { A("> ⚠ 疑似双栏页 \(m.twoColumnPages) —— 已按中缝分栏输出, 请优先复核。"); A() }
        if !m.droppedLines.isEmpty {
            A("### 删掉的页眉页脚页码与碎块")
            A()
            A("误删(章标题被当书眉、小节号被当页码)只能靠这里查出来。")
            A()
            let risk = ["页码", "书眉/页脚(跨页重复)", "书眉(第X章式)", "书眉/页脚(模糊匹配)"]
            let reasons = Array(Set(m.droppedLines.map(\.reason))).sorted {
                let a = risk.firstIndex(of: $0) ?? risk.count, b = risk.firstIndex(of: $1) ?? risk.count
                return a != b ? a < b : $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars)
            }
            for reason in reasons {
                let items = m.droppedLines.filter { $0.reason == reason }
                let shown = items.prefix(12).map { "p\($0.page) `\(cell($0.text, 24))`" }.joined(separator: "、")
                A("- \(reason) \(items.count) 行: \(shown)" + (items.count > 12 ? " …另 \(items.count - 12) 条" : ""))
            }
            A()
        }
    }

    // ---- 嵌字 ----
    if let p = r.pdf {
        H("可搜索 PDF(隐形文字层)")
        A("| 项 | 值 |")
        A("|---|---|")
        if let ret = p.retrieval {
            A(String(format: "| 逐行定位取回率 | **%.4f** (%d/%d 字) |", ret, p.charsRetrieved, p.charsIn))
        } else {
            A("| 逐行定位取回率 | **不适用** —— 本次没有往这份 PDF 里嵌任何文字 |")
        }
        if let w = p.worst, let wp = p.worstPage { A(String(format: "| 最差页 | 第 %d 页 %.4f |", wp, w)) }
        A("| 嵌字页 / 总页 | \(p.embedded) / \(p.pages) |")
        A("| 跳过 | 原生文字层 \(p.skippedNative)、白页闸门 \(p.skippedGate)、无数据 \(p.skippedNoJSON)、无文本 \(p.skippedEmpty) |")
        A("| 行 写入/丢弃 | \(p.linesWritten) / \(p.linesDropped) |")
        A("| 定位抽查 | 命中 \(p.probeFound)/\(p.probeChecked), 平均偏差 \(p.probeMean.map { "\($0)" } ?? "无") pt, 最大 \(p.probeMax.map { "\($0)" } ?? "无") pt |")
        A("| 体积 | \(human(p.sizeIn)) → \(human(p.sizeOut)) (+\(human(p.sizeOut - p.sizeIn))) |")
        A()
        if let ret = p.retrieval, ret < p.minRetrieval { A("> ⚠ 取回率低于阈值 \(p.minRetrieval) —— 文字层可能有部分内容搜不到。"); A() }
        for w in p.warnings.prefix(20) { A("- ⚠ \(w)") }
        if !p.warnings.isEmpty { A() }
        A("> 源文件字节原样保留(增量更新), 文字层以 render_mode=3(不可见)叠在原位, 可搜索、可复制、可选中。")
        A()
    }

    H("这份报告怎么用")
    if !r.degraded.isEmpty { A("0. **先解决上面的降级项** —— 在那之前别把这份产物当成稿。") }
    A("1. 先看「优先复核的页」和「白页闸门」, 在可搜索 PDF 里翻到对应页, 选中文字对照原图。")
    A("2. 两引擎一起错的字交叉验证抓不到。")
    A("3. 识别质量的上限由扫描分辨率决定。取回率正常但错字多, 先提高扫描 dpi, 比任何后处理都有效。")
    return L.joined(separator: "\n") + "\n"
}
