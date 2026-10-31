import Foundation

// src/book_fuse.py fuse() 的移植：Vision + RapidOCR 双引擎自动融合 → fused.json。
// 规则、参数默认值、输出字段、stats 与 Python 一致；唯一的行为改动是碎片重影的文本条件
// （见 containedHost），legacyContain 打开时还原旧行为，只用于对拍。
//
// 铁律（违反过要付代价）：单源行必须收录，丢弃一律计数；比对前必须归一化；术语表在融合之后应用。
// 字符串一律按码点比（pyEq），不用 Swift 的 `==`。

public struct FuseRules: Sendable {
    /// 术语表 [(错误变体, 正确词)]，默认不加载
    public var glossary: [(wrong: String, right: String)] = []

    public var wCJK = 2.0, wAnom = 0.5, wBracket = 0.4, wNoise = 0.3, wConf = 2.0
    /// 置信度中性点。Vision 的三档 conf 与对错无关，一律按 0 计。
    public var confPivot = 0.85

    public var truncRatio = 0.80, truncPenalty = 5.0
    /// 分差小于它算平手 → 取 RapidOCR
    public var tieEps = 0.15

    public var lowConf = 0.60, wideRatio = 2.5
    public var wideMaxChars = 3

    public var containVov = 0.50, containHov = 0.60
    /// 新规则：单源行对配对行的最佳局部编辑距离 / 单源行字数 的上限。
    /// 几何重叠高（垂直、水平都 ≥ containGeoHigh）时放宽；不超过 containShortChars 字的短行不放宽，只认子串。
    public var containMaxDist = 0.15, containMaxDistHighGeo = 0.30
    public var containGeoHigh = 0.90
    public var containShortChars = 6
    /// 还原「整个是子串」的旧文本条件，只用于与 Python 对拍
    public var legacyContain = false

    public var sizeTol = 0.02

    public init() {}
}

public struct FusedLine: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public var text: String
    public var conf: Double
    public var src: String
    public var alt: String?
    public var flag: String

    enum CodingKeys: String, CodingKey { case x, y, w, h, text, conf, src, alt, flag }

    public init(x: Double, y: Double, w: Double, h: Double, text: String, conf: Double,
                src: String, alt: String?, flag: String) {
        self.x = x; self.y = y; self.w = w; self.h = h; self.text = text
        self.conf = conf; self.src = src; self.alt = alt; self.flag = flag
    }

    /// alt 为空时写 null，不省略键（合成的实现用 encodeIfPresent，会丢键）。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
        try c.encode(w, forKey: .w); try c.encode(h, forKey: .h)
        try c.encode(text, forKey: .text); try c.encode(conf, forKey: .conf)
        try c.encode(src, forKey: .src); try c.encode(alt, forKey: .alt)
        try c.encode(flag, forKey: .flag)
    }
}

public struct FusedPage: Codable, Equatable, Sendable {
    public var page: Int
    public var width: Int
    public var height: Int
    public var pdfWidth: Double
    public var pdfHeight: Double
    public var zoom: Double
    public var rotation: Int
    public var image: String?
    public var nativeText: Bool
    public var lines: [FusedLine]
    public var noInk: Bool?
    public var textSource: String?
    /// 这页判定为倒置/横置，已顺时针转这么多度再识别；坐标仍是原页的。只在非 0 时写。
    public var pageRotation: Int?

    enum CodingKeys: String, CodingKey {
        case page, width, height, zoom, rotation, image, lines
        case pdfWidth = "pdf_width", pdfHeight = "pdf_height", nativeText = "native_text"
        case noInk = "no_ink", textSource = "text_source", pageRotation = "page_rotation"
    }
}

public struct FuseStats: Codable, Equatable, Sendable {
    public var pages = 0, lines = 0, both = 0, onlyVision = 0, onlyRapidocr = 0
    public var divergent = 0, lowConf = 0, glossaryHits = 0, droppedEmpty = 0, droppedContained = 0

    enum CodingKeys: String, CodingKey {
        case pages, lines, both, divergent
        case onlyVision = "only_vision", onlyRapidocr = "only_rapidocr", lowConf = "low_conf"
        case glossaryHits = "glossary_hits", droppedEmpty = "dropped_empty"
        case droppedContained = "dropped_contained"
    }
}

public struct FusedDoc: Codable, Equatable, Sendable {
    public var source: String
    public var dpi: Double
    public var engines: [String]
    public var pages: [FusedPage]
    public var stats: FuseStats
}

/// 融合过程的明细，供质量报告用；不进 fused.json。
public final class FuseLog: @unchecked Sendable {
    public struct Drop: Sendable {
        public let page: Int
        public let src: String
        public let text: String
        public let kept: String
        public let distance: Int
        public var newRuleOnly: Bool { distance > 0 }    // 距离 0 是旧规则也会去掉的
    }

    public struct Arbitration: Sendable {
        public let page: Int
        public let winner: String
        public let vision: String
        public let rapidocr: String
    }

    public var drops: [Drop] = []
    public var arbitrations: [Arbitration] = []
    public init() {}
}

public enum FuseError: Error, CustomStringConvertible {
    case wrongEngine(want: String, got: String)
    case sizeMismatch(page: Int, key: String, vision: Int, rapidocr: Int)

    public var description: String {
        switch self {
        case let .wrongEngine(want, got):
            return "引擎顺序反了: 期望 \(want), 实际 \(got)"
        case let .sizeMismatch(page, key, v, r):
            return "第 \(page) 页两引擎的图像\(key)不一致: vision=\(v) rapidocr=\(r)。坐标不在同一个尺度上, 几何配对会全错。"
        }
    }
}

// MARK: - 打分

func scoreText(_ text: String, conf: Double, isRapid: Bool, _ r: FuseRules) -> Double {
    // 求和顺序与 Python 的 parts 一致：浮点加法不满足结合律
    let cjk = r.wCJK * cjkRatio(text)
    let anomaly = -r.wAnom * Double(anomalyCount(text))
    let bracket = -r.wBracket * Double(bracketDefects(text))
    let noise = -r.wNoise * Double(noiseCount(text))
    let confPart = isRapid ? r.wConf * (conf - r.confPivot) : 0.0
    return 0 + cjk + anomaly + bracket + noise + confPart
}

private func hasPrefix(_ s: [Unicode.Scalar], _ p: [Unicode.Scalar]) -> Bool {
    s.count >= p.count && s[..<p.count].elementsEqual(p)
}

private func hasSuffix(_ s: [Unicode.Scalar], _ p: [Unicode.Scalar]) -> Bool {
    s.count >= p.count && s[(s.count - p.count)...].elementsEqual(p)
}

/// -1 = a 被截断，1 = b 被截断，0 = 都不是。必须是前缀/后缀，只是短不算。
func truncation(_ a: String, _ b: String, _ r: FuseRules) -> Int {
    let na = Array(norm(a).unicodeScalars), nb = Array(norm(b).unicodeScalars)
    if na.isEmpty || nb.isEmpty || na == nb { return 0 }
    if na.count < nb.count, Double(na.count) <= r.truncRatio * Double(nb.count),
       hasPrefix(nb, na) || hasSuffix(nb, na) { return -1 }
    if nb.count < na.count, Double(nb.count) <= r.truncRatio * Double(na.count),
       hasPrefix(na, nb) || hasSuffix(na, nb) { return 1 }
    return 0
}

private let leadNoise = Set("、。，．·•…⋯一-—_~^'\"`|/\\()（）[]【】<>《》*+:：;；!！?？$#@%&".unicodeScalars)

/// a 比 b 恰好在行首多一个字符时 +1，反之 -1，其余 0。
func leadExtra(_ a: String, _ b: String) -> Int {
    let na = Array(norm(a).unicodeScalars), nb = Array(norm(b).unicodeScalars)
    if na.count == nb.count + 1, na[1...].elementsEqual(nb) { return 1 }
    if nb.count == na.count + 1, nb[1...].elementsEqual(na) { return -1 }
    return 0
}

/// 只认 norm() 相等，不用 equiv：书里行首的「二」是章节号，折掉就丢了。
func bookEquiv(_ a: String, _ b: String) -> Bool { pyEq(norm(a), norm(b)) }

/// 打分裁决配对但不等的一行。true = Vision 胜。
func visionWins(_ v: Line, _ r: Line, _ rules: FuseRules) -> Bool {
    var sv = scoreText(v.text, conf: v.conf, isRapid: false, rules)
    var sr = scoreText(r.text, conf: r.conf, isRapid: true, rules)
    let trunc = truncation(v.text, r.text, rules)
    if trunc < 0 { sv -= rules.truncPenalty } else if trunc > 0 { sr -= rules.truncPenalty }
    if abs(sv - sr) < rules.tieEps { return false }
    return sv > sr
}

// MARK: - 碎片重影

/// 单源行对配对行的最佳局部对齐编辑距离（Sellers）：s 整条要对齐，host 里从哪开始、到哪结束都不计代价。
func localEditDistance(_ s: [Unicode.Scalar], _ host: [Unicode.Scalar]) -> Int {
    var prev = [Int](repeating: 0, count: host.count + 1)
    for (i, c) in s.enumerated() {
        var cur = [Int](repeating: 0, count: host.count + 1)
        cur[0] = i + 1
        for (j, h) in host.enumerated() {
            cur[j + 1] = min(prev[j] + (c == h ? 0 : 1), prev[j + 1] + 1, cur[j] + 1)
        }
        prev = cur
    }
    return prev.min() ?? s.count
}

/// 单源文本算不算被配对文本包含。
///   旧条件：归一化后整个是子串（对应距离 0，始终成立）。
///   新条件：允许替换的局部对齐。两个检测框把同一行各读一遍时，OCR 的替换会把公共子串切碎
///   （P1 第 236 页 p/P、e/c 两处差异就让覆盖率掉到 0.45），所以不能用最长公共子串。
func textContained(_ single: [Unicode.Scalar], in host: [Unicode.Scalar],
                   vov: Double, hov: Double, _ r: FuseRules) -> Bool {
    let d = localEditDistance(single, host)
    if d == 0 { return true }
    if r.legacyContain || single.count <= r.containShortChars { return false }
    let high = vov >= r.containGeoHigh && hov >= r.containGeoHigh
    return Double(d) <= (high ? r.containMaxDistHighGeo : r.containMaxDist) * Double(single.count)
}

private func spanOverlap(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Double {
    max(0, min(a1, b1) - max(a0, b0))
}

/// 单源行是不是某条 both 行的碎片重影。几何 + 文本双条件，只认这一个方向；多条满足取垂直重叠最大的。
func containedHost(_ s: Line, _ lines: [FusedLine], bothIdx: [Int], _ r: FuseRules) -> Int? {
    let ts = Array(norm(s.text).unicodeScalars)
    guard !ts.isEmpty, s.w > 0, s.h > 0 else { return nil }
    var best: Int?, bestVov = 0.0
    for i in bothIdx {
        let host = lines[i]
        guard host.w > 0, host.h > 0 else { continue }
        let vov = spanOverlap(s.y, s.y + s.h, host.y, host.y + host.h) / min(s.h, host.h)
        if vov <= r.containVov { continue }
        let hov = spanOverlap(s.x, s.x + s.w, host.x, host.x + host.w) / s.w
        if hov <= r.containHov { continue }
        if !textContained(ts, in: Array(norm(host.text).unicodeScalars), vov: vov, hov: hov, r) { continue }
        if vov > bestVov { best = i; bestVov = vov }
    }
    return best
}

let altSep = " ‖ "

/// 被丢弃的读法并进 both 行的 alt：证据不许消失，只是不再独立成行。
func mergeAlt(_ host: inout FusedLine, _ text: String) {
    guard let cur = host.alt, !cur.isEmpty else { host.alt = text; return }
    if !splitScalars(cur, altSep).contains(where: { pyEq($0, text) }) { host.alt = cur + altSep + text }
}

/// Python str.split(sep)：按码点找分隔符。
func splitScalars(_ s: String, _ sep: String) -> [String] {
    let u = Array(s.unicodeScalars), p = Array(sep.unicodeScalars)
    var out: [String] = [], cur = String.UnicodeScalarView(), i = 0
    while i < u.count {
        if i + p.count <= u.count, u[i..<(i + p.count)].elementsEqual(p) {
            out.append(String(cur)); cur = String.UnicodeScalarView(); i += p.count
        } else {
            cur.append(u[i]); i += 1
        }
    }
    out.append(String(cur))
    return out
}

// MARK: - 融合

func medianCharWidth(_ lines: [Line]) -> Double {
    median(lines.compactMap { ln in
        let n = codePointCount(pyStrip(ln.text))
        return ln.w > 0 && n >= 2 ? ln.w / Double(n) : nil
    })
}

func singleFlag(_ ln: Line, isRapid: Bool, medCW: Double, _ r: FuseRules) -> String {
    let n = codePointCount(pyStrip(ln.text))
    if isRapid, ln.conf < r.lowConf { return "low_conf" }
    if medCW > 0, n <= r.wideMaxChars, ln.w > 0, ln.w / Double(n) > r.wideRatio * medCW {
        return "low_conf"
    }
    return "ok"
}

private func line(_ g: Line, text: String, conf: Double, src: String, alt: String?, flag: String) -> FusedLine {
    FusedLine(x: g.x, y: g.y, w: g.w, h: g.h, text: text, conf: conf, src: src, alt: alt, flag: flag)
}

/// 配对行的融合结果：(行, 是否分歧)。
private func fusePair(_ v: Line, _ r: Line, _ rules: FuseRules) -> (FusedLine, Bool) {
    let vt = pyStrip(v.text), rt = pyStrip(r.text)
    let conf = pyRound(r.conf, 4)        // 只有 RapidOCR 的 conf 是连续值

    if bookEquiv(vt, rt) {
        let text: String, alt: String?
        if pyEq(vt, rt) {
            (text, alt) = (rt, nil)
        } else if anomalyCount(vt) < anomalyCount(rt) {
            (text, alt) = (vt, rt)
        } else {
            (text, alt) = (rt, vt)
        }
        return (line(pyEq(text, rt) ? r : v, text: text, conf: conf, src: "both", alt: alt, flag: "ok"), false)
    }

    // 只差行首一个字：打分对这种差异不敏感，会随机吃掉章节号
    let le = leadExtra(vt, rt)
    if le != 0 {
        let (longT, shortT) = le > 0 ? (vt, rt) : (rt, vt)
        let keepLong = !leadNoise.contains(norm(longT).unicodeScalars.first!)
        let text = keepLong ? longT : shortT
        let win = pyEq(text, vt) ? v : r
        return (line(win, text: pyStrip(text), conf: conf, src: "both",
                     alt: pyStrip(keepLong ? shortT : longT), flag: "divergent"), true)
    }

    let (win, lose) = visionWins(v, r, rules) ? (v, r) : (r, v)
    return (line(win, text: pyStrip(win.text), conf: conf, src: "both",
                 alt: pyStrip(lose.text), flag: "divergent"), true)
}

private func cleanLines(_ page: PageDoc?) -> (kept: [Line], dropped: Int) {
    guard let page else { return ([], 0) }
    let kept = page.lines.filter { !pyStrip($0.text).isEmpty }
    return (kept, page.lines.count - kept.count)
}

private func checkGeometry(_ pno: Int, _ vp: PageDoc?, _ rp: PageDoc?, _ r: FuseRules) throws {
    guard let vp, let rp else { return }
    for (key, a, b) in [("width", vp.width, rp.width), ("height", vp.height, rp.height)] where a != 0 && b != 0 {
        if Double(abs(a - b)) > r.sizeTol * Double(max(a, b)) {
            throw FuseError.sizeMismatch(page: pno, key: key, vision: a, rapidocr: b)
        }
    }
}

/// 同一行里顶边差几像素的框不能排乱：先按行高折算出行带。Python 的 sorted 稳定，这里用原下标兜底。
func sortFused(_ lines: [FusedLine]) -> [FusedLine] {
    let heights = lines.map(\.h).filter { $0 > 0 }
    let band = max(1.0, 0.5 * (heights.isEmpty ? 1.0 : median(heights)))
    return lines.enumerated().map { (i, l) in
        (key: ((l.y + l.h / 2) / band).rounded(.toNearestOrEven), x: l.x, i: i, l: l)
    }.sorted {
        if $0.key != $1.key { return $0.key < $1.key }
        if $0.x != $1.x { return $0.x < $1.x }
        return $0.i < $1.i
    }.map(\.l)
}

/// postcheck.apply_glossary 的单条规则：子串替换，返回命中次数。
private func replaceAll(_ text: String, _ wrong: String, _ right: String) -> (String, Int) {
    let parts = splitScalars(text, wrong)
    return (parts.joined(separator: right), parts.count - 1)
}

public func fuse(_ vision: EngineDoc, _ rapid: EngineDoc, rules: FuseRules = FuseRules(),
                 log: FuseLog? = nil) throws -> FusedDoc {
    for (doc, want) in [(vision, "vision"), (rapid, "rapidocr")] where !doc.engine.isEmpty && doc.engine != want {
        throw FuseError.wrongEngine(want: want, got: doc.engine)
    }
    let vpages = Dictionary(vision.pages.map { ($0.page, $0) }, uniquingKeysWith: { _, b in b })
    let rpages = Dictionary(rapid.pages.map { ($0.page, $0) }, uniquingKeysWith: { _, b in b })
    var stats = FuseStats()
    var outPages: [FusedPage] = []

    for pno in Set(vpages.keys).union(rpages.keys).sorted() {
        let vp = vpages[pno], rp = rpages[pno]
        try checkGeometry(pno, vp, rp, rules)

        let (vlines, vdrop) = cleanLines(vp), (rlines, rdrop) = cleanLines(rp)
        stats.droppedEmpty += vdrop + rdrop
        let medCW = medianCharWidth(vlines + rlines)      // 按页算：页与页的字号可能不同

        let (pairs, onlyV, onlyR) = matchLines(vlines, rlines)
        var fused: [FusedLine] = []
        for (i, j) in pairs {
            let (l, divergent) = fusePair(vlines[i], rlines[j], rules)
            fused.append(l)
            stats.both += 1
            if divergent {
                stats.divergent += 1
                log?.arbitrations.append(.init(page: pno, winner: pyEq(l.text, pyStrip(vlines[i].text)) ? "vision" : "rapidocr",
                                               vision: pyStrip(vlines[i].text), rapidocr: pyStrip(rlines[j].text)))
            }
        }

        // 单源行必须收录。唯一的例外是碎片重影：并进 both 行的 alt，并计数。
        let bothIdx = Array(fused.indices)
        for (lines, idxs, isRapid) in [(vlines, onlyV, false), (rlines, onlyR, true)] {
            for i in idxs {
                let ln = lines[i]
                let txt = pyStrip(ln.text)
                if let host = containedHost(ln, fused, bothIdx: bothIdx, rules) {
                    log?.drops.append(.init(page: pno, src: isRapid ? "rapidocr" : "vision", text: txt, kept: fused[host].text,
                                            distance: localEditDistance(Array(norm(txt).unicodeScalars),
                                                                        Array(norm(fused[host].text).unicodeScalars))))
                    mergeAlt(&fused[host], txt)
                    stats.droppedContained += 1
                    continue
                }
                let flag = singleFlag(ln, isRapid: isRapid, medCW: medCW, rules)
                fused.append(line(ln, text: txt, conf: pyRound(ln.conf, 4),
                                  src: isRapid ? "rapidocr" : "vision", alt: nil, flag: flag))
                if isRapid { stats.onlyRapidocr += 1 } else { stats.onlyVision += 1 }
                if flag == "low_conf" { stats.lowConf += 1 }
            }
        }

        let sorted = sortFused(fused)
        let base = (vp ?? rp)!
        outPages.append(FusedPage(page: pno, width: base.width, height: base.height,
                                  pdfWidth: base.pdfWidth, pdfHeight: base.pdfHeight, zoom: base.zoom,
                                  rotation: base.rotation, image: base.image ?? rp?.image,
                                  nativeText: base.nativeText, lines: sorted,
                                  noInk: base.noInk, textSource: base.textSource, pageRotation: base.pageRotation))
        stats.pages += 1
        stats.lines += sorted.count
    }

    // 术语表在融合之后应用，只改 text 不动 alt：alt 是另一引擎当时读成什么的证据。
    for p in outPages.indices {
        for l in outPages[p].lines.indices {
            for rule in rules.glossary {
                let (t, n) = replaceAll(outPages[p].lines[l].text, rule.wrong, rule.right)
                outPages[p].lines[l].text = t
                stats.glossaryHits += n
            }
        }
    }

    return FusedDoc(source: vision.source.isEmpty ? rapid.source : vision.source,
                    dpi: vision.dpi != 0 ? vision.dpi : rapid.dpi,
                    engines: ["vision", "rapidocr"], pages: outPages, stats: stats)
}
