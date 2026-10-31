import Foundation

// src/book_md.py 的移植：fused.json → 段落化 Markdown。
// 规则见 Python 模块头注释，这里只留与移植有关的说明：
//   - 字符串按码点处理；集合键用码点数组（Swift 的 String 按规范等价比较和散列）；
//   - 正则全部手写成等价判断（NSRegularExpression 按 UTF-16 走，\s 语义也不同）；
//   - Python 里靠 id(r) / `is` 判同一对象的地方，这里用 class 引用（Row / PageMetrics）；
//   - sorted 是稳定排序，统一走 stableSorted。
// 判定流水账（opts.report）是给人看的文字，用了 Python 的 repr，没有移植；stats 与丢弃明细全部移植。

// MARK: - 参数

let edgeFrac = 0.12, headMaxRatio = 1.18, fuzzyThresh = 0.6, fuzzyMinCover = 0.6
let headRank = 3, footRank = 2, maxHeadLen = 30, fuzzyMinLen = 3
let chapHeadMinPages = 2, pagenumMinPages = 2, pagenumMaxNeed = 8
let pagenumPagesFrac = 0.25
let isolateGap = 2.5, isolateMaxRatio = 0.85
let blockGap = 1.6
let vertTall = 1.2, vertFrac = 0.6, vertSpread = 0.35
let twocolGutterChars = 2.5, twocolSideFrac = 0.25, twocolCrossFrac = 0.1
let twocolMinRows = 6
let mergeGapChars = 3.0

public let mdMark = "<!-- generated-by: book-line -->"

// MARK: - 输入（宽松解码：缺字段的行不能让整本书失败，见 Python _clean）

public struct MDLine: Decodable, Sendable {
    public var x: Double?, y: Double?, w: Double?, h: Double?
    public var text: String?
    public var conf: Double?
    public var src: String?, flag: String?
    public var vlmBreak: Bool?

    enum CodingKeys: String, CodingKey {
        case x, y, w, h, text, conf, src, flag
        case vlmBreak = "vlm_break"
    }

    public init(x: Double?, y: Double?, w: Double?, h: Double?, text: String?,
                conf: Double? = nil, src: String? = nil, flag: String? = nil) {
        self.x = x; self.y = y; self.w = w; self.h = h; self.text = text
        self.conf = conf; self.src = src; self.flag = flag
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        x = try? c.decode(Double.self, forKey: .x)
        y = try? c.decode(Double.self, forKey: .y)
        w = try? c.decode(Double.self, forKey: .w)
        h = try? c.decode(Double.self, forKey: .h)
        text = try? c.decode(String.self, forKey: .text)
        conf = try? c.decode(Double.self, forKey: .conf)
        src = try? c.decode(String.self, forKey: .src)
        flag = try? c.decode(String.self, forKey: .flag)
        vlmBreak = try? c.decode(Bool.self, forKey: .vlmBreak)
    }
}

public struct MDPage: Decodable, Sendable {
    public var page: Int?
    public var width: Double?, height: Double?
    public var lines: [MDLine]?

    public init(page: Int?, width: Double?, height: Double?, lines: [MDLine]?) {
        self.page = page; self.width = width; self.height = height; self.lines = lines
    }
}

public struct MDDoc: Decodable, Sendable {
    public var pages: [MDPage]?
    public init(pages: [MDPage]?) { self.pages = pages }
}

public struct MDOptions: Sendable {
    public var pageMarks = true
    /// 页标记用分隔线 `---` 而不是注释。段落内部不插（分隔线会打断段落），所以跨页段落里看不到页界。
    public var pageRule = false
    public var indentChars = 1.5
    public var shortEnd = 0.85
    /// 段落切分听 VLM。默认关：抽查页上没测到收益（docs/P5_RESULTS.md）
    public var useVLMBreaks = false
    public init() {}
}

public struct DroppedLine: Encodable, Equatable, Sendable {
    public var page: Int
    public var reason: String
    public var text: String
    public var x: Double, y: Double, w: Double, h: Double
}

public struct MDStats: Encodable, Equatable, Sendable {
    public var pages = 0, linesIn = 0, rows = 0, keptRows = 0, paragraphs = 0, headings = 0
    public var dropped = 0, divergent = 0, lowConf = 0, onlyOneEngine = 0, chars = 0
    public var malformedLines = 0
    public var vlmBreakOverrides = 0
    public var verticalPages: [Int] = [], twoColumnPages: [Int] = []
    public var droppedDetail: [String: Int] = [:]
    public var droppedLines: [DroppedLine] = []

    enum CodingKeys: String, CodingKey {
        case pages, rows, paragraphs, headings, dropped, divergent, chars
        case linesIn = "lines_in", keptRows = "kept_rows", lowConf = "low_conf"
        case onlyOneEngine = "only_one_engine", malformedLines = "malformed_lines"
        case vlmBreakOverrides = "vlm_break_overrides"
        case verticalPages = "vertical_pages", twoColumnPages = "two_column_pages"
        case droppedDetail = "dropped_detail", droppedLines = "dropped_lines"
    }
}

// MARK: - 内部行

final class Row {
    var x: Double, y: Double, w: Double, h: Double
    var text: String
    var conf: Double?
    var src: String?, flag: String?
    var vlmBreak: Bool?

    init(x: Double, y: Double, w: Double, h: Double, text: String,
         conf: Double? = nil, src: String? = nil, flag: String? = nil, vlmBreak: Bool? = nil) {
        self.x = x; self.y = y; self.w = w; self.h = h; self.text = text
        self.conf = conf; self.src = src; self.flag = flag; self.vlmBreak = vlmBreak
    }

    func copy() -> Row { Row(x: x, y: y, w: w, h: h, text: text, conf: conf, src: src, flag: flag, vlmBreak: vlmBreak) }
    var stripped: String { pyStrip(text) }
    var cy: Double { y + h / 2 }
}

func stableSorted<T>(_ a: [T], by less: (T, T) -> Bool) -> [T] {
    a.enumerated().sorted { p, q in
        if less(p.element, q.element) { return true }
        if less(q.element, p.element) { return false }
        return p.offset < q.offset
    }.map(\.element)
}

// MARK: - 字符工具

func hasCJKBook(_ t: String) -> Bool {
    t.unicodeScalars.contains {
        switch $0.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3FFFF: return true
        default: return false
        }
    }
}

func hasWord(_ t: String) -> Bool {
    t.unicodeScalars.contains {
        switch $0.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x3040...0x30FF, 0xAC00...0xD7AF: return true
        default: return false
        }
    }
}

private func isASCIIAlpha(_ c: Unicode.Scalar) -> Bool {
    (0x41...0x5A).contains(c.value) || (0x61...0x7A).contains(c.value)
}

private func isASCIIAlnumMD(_ c: Unicode.Scalar) -> Bool {
    isASCIIAlpha(c) || (0x30...0x39).contains(c.value)
}

/// 拆成三段，才能在接缝处插入行内页标记。
///   'post-' + 'marked' → 去连字符；两侧都是 ASCII 字母数字 → 补一个空格；其余不补。
func splice(_ a: String, _ b: String) -> (String, String, String) {
    guard let last = a.unicodeScalars.last else { return ("", "", b) }
    guard let first = b.unicodeScalars.first else { return (a, "", "") }
    let u = a.unicodeScalars
    if last == "-", u.count >= 2, isASCIIAlpha(u[u.index(u.endIndex, offsetBy: -2)]), isASCIIAlpha(first) {
        return (String(String.UnicodeScalarView(u.dropLast())), "", b)
    }
    if isASCIIAlnumMD(last), isASCIIAlnumMD(first) { return (a, " ", b) }
    return (a, "", b)
}

func quantile(_ vals: [Double], _ q: Double) -> Double {
    if vals.isEmpty { return 0 }
    let s = vals.sorted()
    if s.count == 1 { return s[0] }
    let pos = q * Double(s.count - 1)
    let lo = Int(pos.rounded(.down))
    let hi = min(lo + 1, s.count - 1)
    return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
}

// MARK: - 页级度量

final class PageMetrics {
    var left = 0.0, right = 0.0, width = 0.0, charW = 0.0, medH = 0.0, pitch = 0.0, pageW = 0.0
}

func provisionalMedH(_ rows: [Row]) -> Double {
    median(rows.map(\.h).filter { $0 > 0 })
}

/// 必须在去掉页眉页脚之后调用：页眉是离群值，会污染边距。
func pageMetrics(_ rows: [Row], _ pageW: Double, _ pageH: Double) -> PageMetrics {
    let pm = PageMetrics()
    pm.pageW = pageW
    if rows.isEmpty { return pm }
    pm.medH = provisionalMedH(rows)
    pm.charW = pm.medH != 0 ? pm.medH : pageW * 0.03
    pm.left = quantile(rows.map(\.x), 0.10)
    pm.right = quantile(rows.map { $0.x + $0.w }, 0.90)
    pm.width = pm.right - pm.left
    if pm.width <= 0 {
        pm.left = 0; pm.right = pageW; pm.width = pageW
    }
    let ys = rows.map(\.y).sorted()
    let gaps = zip(ys, ys.dropFirst()).map { $1 - $0 }.filter { $0 > 0 && $0 < pageH * 0.3 }
    if !gaps.isEmpty {
        pm.pitch = median(gaps)
    } else {
        let p = pm.medH * 1.7
        pm.pitch = p != 0 ? p : 1.0
    }
    return pm
}

// MARK: - 噪声过滤

private func bisectLeft(_ a: [Double], _ x: Double) -> Int {
    var lo = 0, hi = a.count
    while lo < hi {
        let m = (lo + hi) / 2
        if a[m] < x { lo = m + 1 } else { hi = m }
    }
    return lo
}

private func bisectRight(_ a: [Double], _ x: Double) -> Int {
    var lo = 0, hi = a.count
    while lo < hi {
        let m = (lo + hi) / 2
        if x < a[m] { hi = m } else { lo = m + 1 }
    }
    return lo
}

func isIsolated(_ l: Row, _ centers: [Double], _ medH: Double) -> Bool {
    if medH == 0 || centers.isEmpty { return false }
    let cy = l.cy
    let i = bisectLeft(centers, cy - 1e-6), j = bisectRight(centers, cy + 1e-6)
    if i == 0 || j >= centers.count { return false }
    return cy - centers[i - 1] > isolateGap * medH && centers[j] - cy > isolateGap * medH
}

func noiseReason(_ l: Row, _ pageW: Double, _ pageH: Double, _ medH: Double, _ centers: [Double]) -> String? {
    let t = l.stripped
    if t.unicodeScalars.isEmpty { return "空行" }
    if !hasCJKBook(t), !hasWord(t) { return "孤立标点或无文字碎块" }
    let n = codePointCount(t)
    let x1 = l.x + l.w, y1 = l.y + l.h
    if n <= 3, x1 < pageW * 0.02 || l.x > pageW * 0.98 || y1 < pageH * 0.02 || l.y > pageH * 0.98 {
        return "贴页缘碎块"
    }
    if medH != 0, l.h < medH * 0.35, n <= 3 { return "微小碎块" }
    // 置信度判据只对 RapidOCR 的连续值生效：Vision 的三档与对错无关
    if let conf = l.conf, conf < 0.4, n <= 2, l.src == nil || l.src == "both" || l.src == "rapidocr" {
        return "低置信碎块"
    }
    if n <= 2, medH != 0, l.h < medH * isolateMaxRatio, isIsolated(l, centers, medH) { return "孤立碎块" }
    return nil
}

// MARK: - 同行碎片合并

private final class RowGroup {
    var items: [Row]
    var x0: Double, x1: Double, y0: Double, y1: Double

    init(_ l: Row) {
        items = [l]; x0 = l.x; x1 = l.x + l.w; y0 = l.y; y1 = l.y + l.h
    }
}

/// 先按垂直重叠分组，再在组内按 x 拼接。splitX 是双栏中缝：跨中缝的两块绝不合并。
func clusterRows(_ lines: [Row], _ charW: Double, splitX: Double? = nil) -> [Row] {
    func side(_ x: Double) -> Int {
        guard let splitX else { return 0 }
        return x >= splitX ? 1 : 0
    }
    var groups: [RowGroup] = []
    for l in stableSorted(lines, by: { ($0.cy, $0.x) < ($1.cy, $1.x) }) {
        let cands: [RowGroup]
        if let last = groups.last, splitX == nil {
            cands = [last]
        } else {
            cands = Array(groups.suffix(4).reversed())
        }
        var placed = false
        for g in cands {
            let ov = min(g.y1, l.y + l.h) - max(g.y0, l.y)
            let sameCol = side(l.x + l.w / 2) == side((g.x0 + g.x1) / 2)
            if ov > 0.5 * min(g.y1 - g.y0, l.h), sameCol {
                let gap = max(l.x - g.x1, g.x0 - (l.x + l.w), 0.0)
                if gap <= mergeGapChars * max(charW, 1.0) {
                    g.items.append(l)
                    g.y0 = min(g.y0, l.y)
                    g.y1 = max(g.y1, l.y + l.h)
                    g.x0 = min(g.x0, l.x)
                    g.x1 = max(g.x1, l.x + l.w)
                    placed = true
                    break
                }
            }
        }
        if !placed { groups.append(RowGroup(l)) }
    }

    return groups.map { g in
        let items = stableSorted(g.items) { $0.x < $1.x }
        let r = items[0].copy()
        var text = r.text
        for nxt in items.dropFirst() {
            let (a, sep, b) = splice(text, nxt.text)
            text = a + sep + b
        }
        r.text = text
        r.x = g.x0; r.y = g.y0
        r.w = g.x1 - g.x0
        // 行高取各块最大值，不取并集：并集会被高低差撑大，而行高是标题判定的主信号
        r.h = items.map(\.h).max()!
        if let c = items.compactMap(\.conf).min() { r.conf = c }
        return r
    }
}

// MARK: - 页码与书眉

private let pagenumStrip = Set("-—–~～·.。、_=|/\\[]()（）<>〈〉《》【】“”\"'".unicodeScalars)
private let cnNum = Set("〇零一二三四五六七八九十百千两".unicodeScalars)
private let cnSmall = Set("〇零一二三四五六七八九十".unicodeScalars)
private let chapUnits = Set("章節节回卷篇部集讲講课課".unicodeScalars)
private let topUnits = Set("章卷篇部".unicodeScalars)
private let subUnits = Set("节節回集讲講课課".unicodeScalars)
private let subSeps = Set("、.．·".unicodeScalars)
private let topWords: [[Unicode.Scalar]] = [
    "自序", "前言", "引言", "导言", "緒论", "绪论", "绪言", "后记", "後記",
    "附录", "附錄", "目录", "目錄", "结语", "結語", "尾声", "尾聲", "致谢", "致謝",
].map { Array($0.unicodeScalars) }

private func isAsciiOrWideDigit(_ c: Unicode.Scalar) -> Bool {
    (0x30...0x39).contains(c.value) || (0xFF10...0xFF19).contains(c.value)
}

private func isChapDigit(_ c: Unicode.Scalar) -> Bool { isAsciiOrWideDigit(c) || cnNum.contains(c) }

private func isStripChar(_ c: Unicode.Scalar) -> Bool { isPySpace(c) || pagenumStrip.contains(c) }

/// str.isdigit()：Numeric_Type 为 Decimal 或 Digit，含 ¹²③ 这类。
private func isPyDigit(_ c: Unicode.Scalar) -> Bool {
    c.properties.numericType == .decimal || c.properties.numericType == .digit
}

private func romanLower(_ c: Unicode.Scalar) -> Unicode.Scalar? {
    switch c {
    case "i", "I", "\u{131}", "\u{130}": return "i"       // re.I 下 i 还匹配 ı / İ
    case "v", "V": return "v"
    case "x", "X": return "x"
    case "l", "L": return "l"
    default: return nil
    }
}

/// ^(?=[ivxl])(xl|l?x{0,3})(ix|iv|v?i{0,3})$，只认 1..89：完整文法会把 mix / dim 也认成数字。
func isRoman(_ core: [Unicode.Scalar]) -> Bool {
    var s: [Unicode.Scalar] = []
    for c in core {
        guard let l = romanLower(c) else { return false }
        s.append(l)
    }
    guard !s.isEmpty else { return false }
    func second(_ i: Int) -> Bool {
        let r = Array(s[i...])
        if r == ["i", "x"] || r == ["i", "v"] { return true }
        var j = 0
        if j < r.count, r[j] == "v" { j += 1 }
        let start = j
        while j < r.count, r[j] == "i", j - start < 3 { j += 1 }
        return j == r.count
    }
    if s.count >= 2, s[0] == "x", s[1] == "l", second(2) { return true }
    for lCount in 0...1 {
        if lCount == 1, s[0] != "l" { continue }
        var i = lCount
        if second(i) { return true }
        var k = 0
        while k < 3, i < s.count, s[i] == "x" {
            i += 1; k += 1
            if second(i) { return true }
        }
    }
    return false
}

enum PageNumberKind { case arabic, long, roman, cjk }

/// 种类决定要不要额外的跨页证据：「1998」多半是年份，「三」「十一」多半是小节号。
func pageNumberKind(_ text: String) -> PageNumberKind? {
    let t = Array(pyStrip(text).unicodeScalars)
    guard !t.isEmpty else { return nil }
    // ^STRIP*(?P<core>.+?)STRIP*$：前缀贪婪、core 懒惰；全是装饰符时前缀回溯让出最后一个字符
    var a = 0
    while a < t.count, isStripChar(t[a]) { a += 1 }
    if a == t.count { a = t.count - 1 }
    var b = t.count
    while b > a + 1, isStripChar(t[b - 1]) { b -= 1 }
    let raw = Array(t[a..<b])
    if raw.contains("\n") { return nil }             // `.` 不匹配换行
    let core = Array(pyStrip(String(String.UnicodeScalarView(raw))).unicodeScalars)
    if core.isEmpty || core.count > 8 { return nil }
    if core.allSatisfy(isPyDigit) { return core.count <= 3 ? .arabic : .long }
    if isRoman(core) { return .roman }
    return core.count <= 6 && core.allSatisfy(cnNum.contains) ? .cjk : nil
}

func needsProof(_ k: PageNumberKind) -> Bool { k == .long || k == .cjk }

/// ^第[数字]{1,8}[章節节…]
func isRunheadChap(_ t: String) -> Bool {
    let s = Array(t.unicodeScalars)
    guard s.first == "第" else { return false }
    var i = 1
    while i < s.count, i <= 8, isChapDigit(s[i]) { i += 1 }
    return i > 1 && i < s.count && chapUnits.contains(s[i])
}

typealias Key = [UInt32]

/// 跨页比对用的键：归一化后抹掉数字（书眉常带页码/章号，逐页不同）。
func headKey(_ text: String) -> Key {
    norm(text).unicodeScalars.filter { !isAsciiOrWideDigit($0) }.map(\.value)
}

/// 页缘 + 排名靠前/靠后 + 够短 + 不比正文大。medH = 0 时关掉字号闸门。
func edgeCandidates(_ rows: [Row], _ pageH: Double, _ medH: Double) -> [Row] {
    if rows.isEmpty { return [] }
    let ordered = stableSorted(rows) { $0.y < $1.y }
    var seen = Set<ObjectIdentifier>(), cand: [Row] = []
    for r in Array(ordered.prefix(headRank)) + Array(ordered.suffix(footRank)) {
        if !seen.insert(ObjectIdentifier(r)).inserted { continue }
        if !(r.cy < pageH * edgeFrac || r.cy > pageH * (1 - edgeFrac)) { continue }
        let n = codePointCount(r.stripped)
        if n == 0 || n > maxHeadLen { continue }
        if medH != 0, r.h > medH * headMaxRatio { continue }
        cand.append(r)
    }
    return cand
}

typealias BodyPage = (height: Double, width: Double, rows: [Row], medH: Double)

func findRunningHeads(_ pages: [BodyPage]) -> Set<Key> {
    let need = max(2, Int((Double(pages.count) * 0.25).rounded(.up)))
    var counter: [Key: Int] = [:]
    for p in pages {
        var keys = Set<Key>()
        for r in edgeCandidates(p.rows, p.height, p.medH) where pageNumberKind(r.stripped) == nil {
            let k = headKey(r.stripped)
            if !k.isEmpty { keys.insert(k) }
        }
        for k in keys { counter[k, default: 0] += 1 }
    }
    return Set(counter.filter { $0.value >= need }.keys)
}

func xZone(_ cx: Double, _ pageW: Double) -> Int {
    if pageW <= 0 { return 1 }
    return cx < pageW / 3 ? 0 : (cx < pageW * 2 / 3 ? 1 : 2)
}

/// 「边 + 横向区位」的键：0x 上、1x 下。
private func slotOf(_ r: Row, _ pageW: Double, _ pageH: Double) -> Int {
    (r.cy < pageH / 2 ? 0 : 10) + xZone(r.x + r.w / 2, pageW)
}

func findPageNumberSlots(_ pages: [BodyPage]) -> Set<Int> {
    let need = min(max(pagenumMinPages, Int((Double(pages.count) * pagenumPagesFrac).rounded(.up))), pagenumMaxNeed)
    var counter: [Int: Int] = [:]
    for p in pages {
        var slots = Set<Int>()
        for r in edgeCandidates(p.rows, p.height, p.medH) where pageNumberKind(r.stripped) != nil {
            slots.insert(slotOf(r, p.width, p.height))
        }
        for k in slots { counter[k, default: 0] += 1 }
    }
    return Set(counter.filter { $0.value >= need }.keys)
}

/// 「第X章 …」只有跨页重复过才是书眉；全书只出现一次的是章标题。
func findChapterHeads(_ pages: [BodyPage]) -> Set<Key> {
    var counter: [Key: Int] = [:]
    for p in pages {
        var keys = Set<Key>()
        for r in p.rows {
            let t = r.stripped, n = codePointCount(t)
            if n == 0 || n > maxHeadLen || !isRunheadChap(t) { continue }
            let k = headKey(t)
            if !k.isEmpty { keys.insert(k) }
        }
        for k in keys { counter[k, default: 0] += 1 }
    }
    return Set(counter.filter { $0.value >= chapHeadMinPages }.keys)
}

private func isSub(_ a: Key, of b: Key) -> Bool {
    if a.count > b.count { return false }
    if a.isEmpty { return true }
    return (0...(b.count - a.count)).contains { b[$0..<($0 + a.count)].elementsEqual(a) }
}

/// OCR 对页眉本身也逐页读得不同。子串分支带长度约束：书眉「灯下的来信」不能吃掉两字短行「来信」。
func fuzzyHead(_ key: Key, _ heads: Set<Key>) -> Bool {
    if key.isEmpty { return false }
    for h in heads where !h.isEmpty {
        if key == h { return true }
        let lo = min(key.count, h.count), hi = max(key.count, h.count)
        if isSub(key, of: h) || isSub(h, of: key),
           lo >= fuzzyMinLen, Double(lo) >= fuzzyMinCover * Double(hi) {
            return true
        }
        let a = Set(key), b = Set(h)
        if !a.isEmpty, !b.isEmpty,
           Double(a.intersection(b).count) / Double(max(a.count, b.count)) >= fuzzyThresh {
            return true
        }
    }
    return false
}

// MARK: - 标题

private func startsWith(_ s: ArraySlice<Unicode.Scalar>, _ p: [Unicode.Scalar]) -> Bool {
    s.count >= p.count && s.prefix(p.count).elementsEqual(p)
}

func keyTop(_ t: String) -> Bool {
    let all = Array(t.unicodeScalars)
    let s = all.drop(while: isPySpace)
    guard let c0 = s.first else { return false }
    if c0 == "第" {
        var i = s.startIndex + 1
        while i < s.endIndex, i - s.startIndex <= 8, isChapDigit(all[i]) { i += 1 }
        if i > s.startIndex + 1, i < s.endIndex, topUnits.contains(all[i]) { return true }
    }
    if c0 == "序" {
        if s.count == 1 { return true }
        if s.count == 2, s.last == "言" || s.last == "章" { return true }
    }
    if c0 == "跋", s.count == 1 { return true }
    return topWords.contains { startsWith(s, $0) }
}

func keySub(_ t: String) -> Bool {
    let all = Array(t.unicodeScalars)
    let s = Array(all.drop(while: isPySpace))
    guard let c0 = s.first else { return false }
    if c0 == "第" {
        var i = 1
        while i < s.count, i <= 8, isChapDigit(s[i]) { i += 1 }
        if i > 1, i < s.count, subUnits.contains(s[i]) { return true }
    }
    // [0-9０-９〇零一二…十]{1,4}\s*[、.．·]\s*\S
    var i = 0
    while i < s.count, i < 4, isAsciiOrWideDigit(s[i]) || cnSmall.contains(s[i]) { i += 1 }
    if i > 0 {
        var j = i
        while j < s.count, isPySpace(s[j]) { j += 1 }
        if j < s.count, subSeps.contains(s[j]) {
            j += 1
            while j < s.count, isPySpace(s[j]) { j += 1 }
            if j < s.count { return true }
        }
    }
    // [〇零一二…十]{1,3}[\s　]+\S
    var k = 0
    while k < s.count, k < 3, cnSmall.contains(s[k]) { k += 1 }
    if k > 0, k < s.count, isPySpace(s[k]) {
        var j = k
        while j < s.count, isPySpace(s[j]) { j += 1 }
        if j < s.count { return true }
    }
    return false
}

/// ^\s*[〇零一二…十]{1,3}[一-鿿]：数字本身也在汉字区，贪婪匹配要能回溯。
func keySubWeak(_ t: String) -> Bool {
    let s = Array(Array(t.unicodeScalars).drop(while: isPySpace))
    var run = 0
    while run < s.count, run < 3, cnSmall.contains(s[run]) { run += 1 }
    guard run > 0 else { return false }
    return (1...run).contains { $0 < s.count && isBasicCJK(s[$0]) }
}

func headingLevel(_ row: Row, _ pm: PageMetrics) -> Int? {
    let t = row.stripped, n = codePointCount(t)
    if n == 0 || n > 40 { return nil }
    let ratio = pm.medH != 0 ? row.h / pm.medH : 1.0
    var score = 0
    if ratio >= 1.6 { score += 3 } else if ratio >= 1.25 { score += 2 } else if ratio >= 1.12 { score += 1 }

    let leftGap = row.x - pm.left, rightGap = pm.right - (row.x + row.w)
    let inset = pm.width > 0 && leftGap > pm.width * 0.06 && rightGap > pm.width * 0.06
    let rowC = row.x + row.w / 2
    let centered = inset && (abs(leftGap - rightGap) <= pm.width * 0.12
                             || (pm.pageW > 0 && abs(rowC - pm.pageW / 2) <= pm.pageW * 0.06))
    if centered { score += 2 }
    if n <= 20 { score += 1 }

    let top = keyTop(t), sub = keySub(t)
    if top { score += 3 } else if sub { score += 2 } else if keySubWeak(t) { score += 1 }

    if score < 4 { return nil }
    return top || ratio >= 1.6 ? 1 : 2
}

// MARK: - 竖排 / 双栏

func looksVertical(_ lines: [Row], _ pageW: Double) -> Bool {
    let cand = lines.filter { codePointCount($0.stripped) >= 2 }
    if cand.count < 3 { return false }
    let tall = cand.filter { $0.h > $0.w * vertTall }
    if Double(tall.count) < vertFrac * Double(cand.count) { return false }
    let xs = tall.map(\.x)
    return xs.max()! - xs.min()! > pageW * vertSpread
}

/// 找一条贯穿多数行的空白竖带（中缝）。要在合行之前调用：中缝窄时合行会先把两栏粘起来。
func looksTwoColumn(_ lines: [Row], _ charW: Double) -> (Double, Double)? {
    let cand = lines.filter { $0.w > 0 && !$0.stripped.unicodeScalars.isEmpty }
    let n = cand.count
    if n < twocolMinRows { return nil }
    let xLo = cand.map(\.x).min()!, xHi = cand.map { $0.x + $0.w }.max()!
    let span = xHi - xLo
    if span <= 0 || charW <= 0 { return nil }
    let nb = 240
    let bw = span / Double(nb)
    var cover = [Int](repeating: 0, count: nb)
    for l in cand {
        let i0 = max(0, Int((l.x - xLo) / bw))
        let i1 = min(nb - 1, Int((l.x + l.w - xLo) / bw))
        if i0 <= i1 { for i in i0...i1 { cover[i] += 1 } }
    }
    let allow = Int(Double(n) * twocolCrossFrac)
    var best = (0, 0, 0), run = 0
    for i in 0..<nb {
        if cover[i] <= allow {
            run += 1
            if run > best.0, i - run + 1 > 0, i < nb - 1 { best = (run, i - run + 1, i) }
        } else {
            run = 0
        }
    }
    if best.0 == 0 { return nil }
    let g0 = xLo + Double(best.1) * bw, g1 = xLo + Double(best.2 + 1) * bw
    if g1 - g0 < twocolGutterChars * charW { return nil }
    let c = (g0 + g1) / 2
    if !(xLo + span * 0.2 < c && c < xLo + span * 0.8) { return nil }
    let left = cand.filter { $0.x + $0.w <= g0 + bw }, right = cand.filter { $0.x >= g1 - bw }
    let need = max(2, Int(Double(n) * twocolSideFrac))
    if left.count < need || right.count < need { return nil }
    return (g0, g1)
}

// MARK: - 主流程

/// <!--.*?--> 全部去掉后的码点数（跨行）。字数不算行内的页标记。
func charsWithoutComments(_ t: String) -> Int {
    let s = Array(t.unicodeScalars), open = Array("<!--".unicodeScalars), close = Array("-->".unicodeScalars)
    var i = 0, n = 0
    while i < s.count {
        if i + 4 <= s.count, s[i..<(i + 4)].elementsEqual(open) {
            var j = i + 4
            while j + 3 <= s.count, !s[j..<(j + 3)].elementsEqual(close) { j += 1 }
            if j + 3 <= s.count { i = j + 3; continue }
        }
        n += 1; i += 1
    }
    return n
}

/// \n{3,} → \n\n
private func collapseNewlines(_ s: String) -> String {
    var out = String.UnicodeScalarView(), run = 0
    for c in s.unicodeScalars {
        if c == "\n" {
            run += 1
            if run <= 2 { out.append(c) }
        } else {
            run = 0
            out.append(c)
        }
    }
    return String(out)
}

private final class Prev {
    let heading: Bool
    let x: Double, y: Double, w: Double, h: Double
    let pm: PageMetrics?

    init(heading: Bool, r: Row? = nil, pm: PageMetrics? = nil) {
        self.heading = heading
        x = r?.x ?? 0; y = r?.y ?? 0; w = r?.w ?? 0; h = r?.h ?? 0
        self.pm = pm
    }
}

private func isParaStart(_ prev: Prev?, _ row: Row, _ pm: PageMetrics, _ o: MDOptions) -> Bool {
    guard let prev, !prev.heading, let ppm = prev.pm else { return true }
    if row.x >= pm.left + o.indentChars * pm.charW { return true }
    if ppm.width > 0, (prev.x + prev.w - ppm.left) / ppm.width < o.shortEnd { return true }
    // 跨页的 y 之差没有意义，只在同一页比
    return ppm === pm && pm.pitch > 0 && row.y - prev.y > blockGap * pm.pitch
}

private struct Prepped {
    var page: MDPage
    var rows: [Row]
    var med: Double
    var vertical: Bool
    var band: (Double, Double)?
}

private struct PageBody {
    var page: MDPage
    var body: [Row]
    var pm: PageMetrics
    var vertical: Bool
    var mark: Bool
    var warn: String?
}

public func toMarkdown(_ doc: MDDoc, options o: MDOptions = MDOptions()) -> (md: String, stats: MDStats) {
    let pages = doc.pages ?? []
    var st = MDStats()
    st.pages = pages.count

    func drop(_ reason: String, _ pno: Int, _ r: Row) {
        st.droppedDetail[reason, default: 0] += 1
        st.droppedLines.append(DroppedLine(page: pno, reason: reason, text: r.stripped,
                                           x: r.x, y: r.y, w: r.w, h: r.h))
    }

    func clean(_ l: MDLine) -> Row {
        if l.x == nil || l.y == nil || l.w == nil || l.h == nil || l.text == nil { st.malformedLines += 1 }
        return Row(x: l.x ?? 0, y: l.y ?? 0, w: l.w ?? 0, h: l.h ?? 0, text: l.text ?? "",
                   conf: l.conf, src: l.src, flag: l.flag, vlmBreak: l.vlmBreak)
    }

    func size(_ v: Double?) -> Double {
        if let v, v != 0 { return v }
        return 1
    }

    func pageNo(_ p: MDPage, _ i: Int) -> Int {
        if let n = p.page, n != 0 { return n }
        return i
    }

    // 第 1 遍：噪声过滤 + 碎片合行 + 竖排/双栏检测
    var prepped: [Prepped] = []
    for (i0, p) in pages.enumerated() {
        let lines = (p.lines ?? []).map(clean)
        st.linesIn += lines.count
        for l in lines {
            if l.flag == "divergent" { st.divergent += 1 } else if l.flag == "low_conf" { st.lowConf += 1 }
            if l.src == "vision" || l.src == "rapidocr" { st.onlyOneEngine += 1 }
        }
        let pageW = size(p.width), pageH = size(p.height)
        let pno0 = pageNo(p, i0 + 1)
        if looksVertical(lines, pageW) {
            st.verticalPages.append(pno0)
            let sorted = stableSorted(lines.map { $0.copy() }) { (-$0.x, $0.y) < (-$1.x, $1.y) }
            prepped.append(Prepped(page: p, rows: sorted, med: provisionalMedH(lines), vertical: true, band: nil))
            continue
        }
        let med0 = provisionalMedH(lines)
        let centers = lines.map(\.cy).sorted()
        var kept: [Row] = []
        for l in lines {
            if let why = noiseReason(l, pageW, pageH, med0, centers) {
                drop(why, pno0, l)
            } else {
                kept.append(l)
            }
        }
        let cw = med0 != 0 ? med0 : pageW * 0.03
        let band = looksTwoColumn(kept, cw)
        if band != nil { st.twoColumnPages.append(pno0) }
        let rows = clusterRows(kept, cw, splitX: band.map { ($0.0 + $0.1) / 2 })
        st.rows += rows.count
        let m = provisionalMedH(rows)
        prepped.append(Prepped(page: p, rows: rows, med: m != 0 ? m : med0, vertical: false, band: band))
    }

    // 第 2 遍：页眉页脚（必须跨页统计）
    let bodyPages: [BodyPage] = prepped.filter { !$0.vertical }.map {
        (height: size($0.page.height), width: size($0.page.width), rows: $0.rows, medH: $0.med)
    }
    let heads = findRunningHeads(bodyPages)
    let chapHeads = findChapterHeads(bodyPages)
    let pnSlots = findPageNumberSlots(bodyPages)

    var pageBodies: [PageBody] = []
    for (ib, e) in prepped.enumerated() {
        let p = e.page, pageW = size(p.width), pageH = size(p.height)
        let pno = pageNo(p, ib + 1)
        if e.vertical {
            pageBodies.append(PageBody(page: p, body: e.rows, pm: pageMetrics(e.rows, pageW, pageH),
                                       vertical: true, mark: true, warn: nil))
            continue
        }
        let candIds = Set(edgeCandidates(e.rows, pageH, e.med).map { ObjectIdentifier($0) })
        // 字号闸门也挡住了框高略高于正文的页码；对已有跨页位置证据的页码放宽
        let looseIds = Set(edgeCandidates(e.rows, pageH, 0).map { ObjectIdentifier($0) }).subtracting(candIds)
        var body: [Row] = []
        for r in e.rows {
            let id = ObjectIdentifier(r)
            if candIds.contains(id) {
                let t = r.stripped
                let slot = slotOf(r, pageW, pageH)
                if let kind = pageNumberKind(t), !needsProof(kind) || pnSlots.contains(slot) {
                    drop("页码", pno, r)
                    continue
                }
                let k = headKey(t)
                if heads.contains(k) {
                    drop("书眉/页脚(跨页重复)", pno, r)
                    continue
                }
                if isRunheadChap(t), chapHeads.contains(k) {
                    drop("书眉(第X章式)", pno, r)
                    continue
                }
                if fuzzyHead(k, heads) {
                    drop("书眉/页脚(模糊匹配)", pno, r)
                    continue
                }
            } else if looseIds.contains(id) {
                if pageNumberKind(r.stripped) != nil, pnSlots.contains(slotOf(r, pageW, pageH)) {
                    drop("页码(框略高于正文, 凭跨页证据)", pno, r)
                    continue
                }
            }
            body.append(r)
        }
        st.keptRows += body.count

        if let band = e.band {
            let warn = String(format: "<!-- WARNING: 第 %ld 页疑似双栏(中缝 x≈%.0f~%.0f), 已按中缝切成左右两栏分别成段; 分栏识别可能出错, 请优先复核本页 -->", pno, band.0, band.1)
            let mid = (band.0 + band.1) / 2
            let left = body.filter { $0.x + $0.w / 2 < mid }, right = body.filter { $0.x + $0.w / 2 >= mid }
            // 每栏各自算版心度量：用整页宽去量，每一行都「右端留白」
            pageBodies.append(PageBody(page: p, body: left, pm: pageMetrics(left, pageW, pageH),
                                       vertical: false, mark: true, warn: warn))
            pageBodies.append(PageBody(page: p, body: right, pm: pageMetrics(right, pageW, pageH),
                                       vertical: false, mark: false, warn: nil))
            continue
        }
        pageBodies.append(PageBody(page: p, body: body, pm: pageMetrics(body, pageW, pageH),
                                   vertical: false, mark: true, warn: nil))
    }

    // 第 3 遍：标题 + 段落合并 + 页标记
    var blocks: [String] = [], pending: [String] = []
    var cur: String?
    var prev: Prev?

    func flush() {
        if let c = cur {
            let t = pyStrip(c)
            if !t.unicodeScalars.isEmpty {
                blocks.append(t)
                st.paragraphs += 1
                st.chars += charsWithoutComments(t)
            }
            cur = nil
        }
    }

    func flushPending() {
        blocks.append(contentsOf: pending)
        pending = []
    }

    for (i, pb) in pageBodies.enumerated() {
        let pno = pageNo(pb.page, i + 1)
        if o.pageMarks, pb.mark { pending.append(o.pageRule ? "---" : "<!-- page \(pno) -->") }
        if pb.warn != nil || !pb.mark {
            // 双栏：告警是块级 HTML，本来就该打断；右栏同样断开，左栏末行和右栏首行毫无关系
            flush()
            prev = nil
            flushPending()
            if let w = pb.warn { blocks.append(w) }
        }

        if pb.vertical {
            flush()
            prev = nil
            flushPending()
            blocks.append("<!-- WARNING: 第 \(pno) 页疑似竖排(高>宽且分列), 本版不支持竖排版面, 以下按识别到的行原样输出 -->")
            for r in pb.body {
                let t = r.stripped
                if !t.unicodeScalars.isEmpty {
                    blocks.append(t)
                    st.chars += codePointCount(t)
                }
            }
            continue
        }

        for r in pb.body {
            let text = r.stripped
            if let lvl = headingLevel(r, pb.pm) {
                flush()
                flushPending()
                blocks.append(String(repeating: "#", count: lvl) + " " + text)
                st.headings += 1
                st.chars += codePointCount(text)
                prev = Prev(heading: true)
                continue
            }
            var start = cur == nil || isParaStart(prev, r, pb.pm, o)
            // 断句信 VLM，但首行缩进是版面上的硬证据：VLM 说「不换段」压不过它
            let indented = r.x >= pb.pm.left + o.indentChars * pb.pm.charW
            if o.useVLMBreaks, cur != nil, let b = r.vlmBreak, b != start, b || !indented {
                start = b
                st.vlmBreakOverrides += 1
            }
            if start {
                flush()
                flushPending()
                cur = text
            } else {
                // 续行的页标记留在行内：单独成行的 HTML 注释会把跨页段落切断
                let (a, sep, b) = splice(cur ?? "", text)
                cur = a + sep + (o.pageRule ? "" : pending.joined()) + b
                pending = []
            }
            prev = Prev(heading: false, r: r, pm: pb.pm)
        }
    }

    flush()
    flushPending()

    st.dropped = st.droppedDetail.values.reduce(0, +)
    let joined = blocks.filter { !pyStrip($0).unicodeScalars.isEmpty }.joined(separator: "\n\n")
    let md = collapseNewlines(joined)
    return (md.unicodeScalars.isEmpty ? "" : md + "\n", st)
}

/// run_books 写文件时加的归属标记：写在最前面，book_md 的输出一个字不动。
public func withMark(_ md: String) -> String {
    let body = String(String.UnicodeScalarView(md.unicodeScalars.drop { $0 == "\n" }))
    return mdMark + "\n\n" + body
}
