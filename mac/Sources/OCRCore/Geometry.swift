// python-final:src/crosscheck.py 的移植：两个引擎的行按几何位置贪心配对（1:1）。

/// 垂直中心距离 < 行高的这个比例，且水平有重叠
let vertTol = 0.6

protocol Box {
    var x: Double { get }
    var y: Double { get }
    var w: Double { get }
    var h: Double { get }
}

extension Line: Box {}

func verticalOverlap(_ a: some Box, _ b: some Box) -> Double {
    let inter = max(0, min(a.y + a.h, b.y + b.h) - max(a.y, b.y))
    return inter / max(1e-6, min(a.h, b.h))
}

func horizontalOverlap(_ a: some Box, _ b: some Box) -> Double {
    let inter = max(0, min(a.x + a.w, b.x + b.w) - max(a.x, b.x))
    return inter / max(1e-6, min(a.w, b.w))
}

/// 返回 (配对, A 独有, B 独有)，下标都指向输入数组。
/// 与 Python 一致：按 A 的顺序逐行找 B 里得分最高且未被占用的，得分须严格更大才替换。
public func matchLines(_ la: [Line], _ lb: [Line]) -> (pairs: [(Int, Int)], onlyA: [Int], onlyB: [Int]) {
    var usedB = Set<Int>()
    var pairs: [(Int, Int)] = []
    for (i, a) in la.enumerated() {
        var best = -1, bestScore = 0.0
        for (j, b) in lb.enumerated() where !usedB.contains(j) {
            let v = verticalOverlap(a, b), h = horizontalOverlap(a, b)
            if v < vertTol || h <= 0 { continue }
            if v + h > bestScore { best = j; bestScore = v + h }
        }
        if best >= 0 { usedB.insert(best); pairs.append((i, best)) }
    }
    let pairedA = Set(pairs.map(\.0))
    return (pairs, la.indices.filter { !pairedA.contains($0) }, lb.indices.filter { !usedB.contains($0) })
}

/// statistics.median：偶数个取中间两个的平均。
func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    guard !s.isEmpty else { return 0 }
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}
