import Foundation

// Phase 5：VLM 读法并入双引擎融合。原则（P1 结论）：字形信 CTC。
//   - 框和行结构全部来自 PP-OCR / Vision；VLM 没有坐标，只投票。
//   - 两引擎已有分歧的行，VLM 对应片段更支持败者才翻转；没分歧的行不改。
//   - VLM 独有的内容一律不进正文，只记进报告：VLM 在白页上会编造。
// 运行时无关：输入是一页 VLM 文本，推理走哪条路不影响这里。

public struct VLMRules: Sendable {
    /// 输出字数上限 = 估计字数 × ratio + slack
    public var maxRatio = 1.5, slack = 50
    /// 循环判定：周期不超过 maxPeriod 的片段在尾部重复至少 minRepeat 次
    public var maxPeriod = 200, minRepeat = 5
    /// 这么长的连续 VLM 独有内容记为「无对应」
    public var orphanChars = 8
    /// 翻转要求：败者与 VLM 片段的距离比 ≤ 它
    public var flipMaxDist = 0.34
    public init() {}
}

public struct VLMGate: Sendable, Equatable {
    public var text: String
    public var truncatedByLength = false, loopCut = false
    public var rawChars = 0, keptChars = 0
}

public struct VLMPageReport: Sendable {
    public var page: Int
    public var gate: VLMGate
    public var flips: [(line: Int, from: String, to: String, vlm: String)] = []
    public var orphans: [String] = []
    public var skippedNoInk = false
}

/// Markdown 标记不是书的内容。
private func stripMarkup(_ s: String) -> [Unicode.Scalar] {
    var out: [Unicode.Scalar] = [], inTag = false, tagLen = 0
    let u = Array(s.unicodeScalars)
    for c in u {
        if inTag {
            tagLen += 1
            if c == ">" || tagLen > 40 { inTag = false }
            continue
        }
        if c == "<" { inTag = true; tagLen = 0; continue }
        if "#*`|_~".unicodeScalars.contains(c) { continue }
        out.append(c)
    }
    return out
}

/// 比较用的折叠：单字符 norm，弯直引号算一个。去空白。
func foldChar(_ c: Unicode.Scalar) -> Unicode.Scalar? {
    if isPySpace(c) { return nil }
    switch c {
    case "“", "”", "＂", "\"": return "\""
    case "‘", "’", "＇", "'": return "'"
    default:
        let n = norm(String(c)).unicodeScalars
        return n.first ?? c
    }
}

func folded(_ s: String) -> [Unicode.Scalar] { stripMarkup(s).compactMap(foldChar) }

/// 防编造闸门。estimate 是这页的估计字数（CTC 读到的字数，它和墨迹量同步）。
public func gateVLM(_ text: String, estimate: Int, rules r: VLMRules = VLMRules()) -> VLMGate {
    var u = stripMarkup(text)
    var g = VLMGate(text: "", rawChars: u.count, keptChars: 0)
    // 循环：尾部同一片段反复出现
    let n = u.count
    if n >= r.maxPeriod {
        for p in 1...r.maxPeriod where n >= p * r.minRepeat {
            var k = 1
            while (k + 1) * p <= n, u[(n - (k + 1) * p)..<(n - k * p)].elementsEqual(u[(n - p)..<n]) { k += 1 }
            if k >= r.minRepeat {
                u.removeLast((k - 1) * p)
                g.loopCut = true
                break
            }
        }
    }
    let cap = Int(Double(estimate) * r.maxRatio) + r.slack
    if u.count > cap {
        u.removeLast(u.count - cap)
        g.truncatedByLength = true
    }
    var v = String.UnicodeScalarView()
    v.append(contentsOf: u)
    g.text = String(v)
    g.keptChars = u.count
    return g
}

/// 全局对齐（Needleman–Wunsch，单位代价）。返回 a 的每个位置对应 b 的下标，缺失为 -1。
func alignChars(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> [Int] {
    let n = a.count, m = b.count
    if n == 0 { return [] }
    if m == 0 { return [Int](repeating: -1, count: n) }
    var trace = [UInt8](repeating: 0, count: (n + 1) * (m + 1))
    var prev = Array(0...m), cur = [Int](repeating: 0, count: m + 1)
    for j in 0...m { trace[j] = 2 }
    for i in 1...n {
        cur[0] = i
        trace[i * (m + 1)] = 1
        for j in 1...m {
            let sub = prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
            let del = prev[j] + 1, ins = cur[j - 1] + 1
            if sub <= del, sub <= ins {
                cur[j] = sub
            } else if del <= ins {
                cur[j] = del
                trace[i * (m + 1) + j] = 1
            } else {
                cur[j] = ins
                trace[i * (m + 1) + j] = 2
            }
        }
        swap(&prev, &cur)
    }
    var map = [Int](repeating: -1, count: n)
    var i = n, j = m
    while i > 0 || j > 0 {
        switch trace[i * (m + 1) + j] {
        case 0:
            map[i - 1] = a[i - 1] == b[j - 1] ? j - 1 : -2 - (j - 1)    // 替换也记位置，编码成负数
            i -= 1
            j -= 1
        case 1: i -= 1
        default: j -= 1
        }
    }
    return map
}

private func editDistance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var prev = Array(0...b.count)
    for (i, x) in a.enumerated() {
        var cur = [i + 1] + [Int](repeating: 0, count: b.count)
        for (j, y) in b.enumerated() { cur[j + 1] = min(prev[j] + (x == y ? 0 : 1), prev[j + 1] + 1, cur[j] + 1) }
        prev = cur
    }
    return prev[b.count]
}

/// 把一页 VLM 文本并进融合结果。返回新的行（顺序不变）和报告。
public func applyVLM(_ page: FusedPage, vlm: String?, rules r: VLMRules = VLMRules()) -> (FusedPage, VLMPageReport) {
    var out = page
    var rep = VLMPageReport(page: page.page, gate: VLMGate(text: ""))
    if page.noInk == true {
        rep.skippedNoInk = true          // 无墨迹页不调用 VLM：它在白页上会编造
        return (out, rep)
    }
    guard let vlm else { return (out, rep) }
    let order = stableSorted(Array(page.lines.indices)) {
        let a = page.lines[$0], b = page.lines[$1]
        return (a.y, a.x) < (b.y, b.x)
    }
    var ctc: [Unicode.Scalar] = [], ranges: [Int: Range<Int>] = [:]
    for i in order {
        let f = folded(page.lines[i].text)
        ranges[i] = ctc.count..<(ctc.count + f.count)
        ctc += f
    }
    rep.gate = gateVLM(vlm, estimate: ctc.count, rules: r)
    let v = folded(rep.gate.text)
    let map = alignChars(ctc, v)
    func pos(_ k: Int) -> Int? {
        let m = map[k]
        return m >= 0 ? m : (m <= -2 ? -2 - m : nil)
    }

    // VLM 独有：没有被任何 CTC 字对上的连续片段
    var covered = [Bool](repeating: false, count: v.count)
    for k in map.indices { if let p = pos(k) { covered[p] = true } }
    var run: [Unicode.Scalar] = []
    for (k, c) in covered.enumerated() {
        if !c { run.append(v[k]) }
        if c || k == covered.count - 1 {
            if run.count >= r.orphanChars {
                var s = String.UnicodeScalarView()
                s.append(contentsOf: run)
                rep.orphans.append(String(s))
            }
            run = []
        }
    }

    // 断句信 VLM：VLM 换行处对应的 CTC 行就是段首。页首没有判断（可能是上一页的续段）
    var starts = Set<Int>(), seen = 0
    for segLine in rep.gate.text.components(separatedBy: "\n") {
        let n = folded(segLine).count
        if n > 0 {
            if seen > 0 { starts.insert(seen) }
            seen += n
        }
    }
    for i in order {
        guard let rg = ranges[i], !rg.isEmpty, let p = rg.compactMap(pos).first, p > 0 else { continue }
        out.lines[i].vlmBreak = starts.contains(p)
    }

    for i in order where page.lines[i].flag == "divergent" {
        guard let rg = ranges[i], !rg.isEmpty, let alt = page.lines[i].alt else { continue }
        let ps = rg.compactMap(pos)
        guard let lo = ps.min(), let hi = ps.max() else { continue }
        let seg = Array(v[lo...hi])
        let cur = folded(page.lines[i].text)
        let other = splitScalars(alt, altSep)[0]
        let oth = folded(other)
        if oth.isEmpty { continue }
        let dc = editDistance(cur, seg), de = editDistance(oth, seg)
        if de < dc, Double(de) <= r.flipMaxDist * Double(max(1, seg.count)) {
            var s = String.UnicodeScalarView()
            s.append(contentsOf: seg)
            rep.flips.append((i, page.lines[i].text, other, String(s)))
            out.lines[i].alt = page.lines[i].text
            out.lines[i].text = other
        }
    }
    return (out, rep)
}
