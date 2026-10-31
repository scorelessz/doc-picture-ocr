import Foundation

// src/normalize.py norm() 的移植：比对前的等价归一化，消除「同一字形被不同引擎读成不同字符」
// 造成的假分歧（不归一化时 79% 的分歧是假的）。只用于比对，不改写输出文本。
//
// 与 Python 逐位一致的细节：
//   - 按 Unicode 标量（码点）处理，不按 Swift 的 Character（字素簇）—— Python 的 str 是码点序列；
//   - 等价组按表序建映射，后面的组覆盖前面的（'"' 同时出现在两组里，最终映射到 '”'）；
//   - 省略号折叠必须在 NFKC **之后**（NFKC 把 '…' 拆成 '...'，'⋯' 不变，顺序反了两者永远不等）。

private let equivGroups = [
    "△▲Δ∆AＡ^◇◆",
    "（(", "）)", "：:", "，,", "；;", "！!", "？?",
    "【〔[［", "】〕]］", "｛{", "｝}",
    "“\"＂", "”\"＂", "‘'", "’'",
    "—－-–", "…⋯‥",
]

private let equivMap: [Unicode.Scalar: Unicode.Scalar] = {
    var m: [Unicode.Scalar: Unicode.Scalar] = [:]
    for g in equivGroups {
        let s = Array(g.unicodeScalars)
        for ch in s { m[ch] = s[0] }
    }
    return m
}()

private let ellipsisRun = Set("…⋯‥•·․.".unicodeScalars)
private let ellipsisSingle = Set("…⋯‥".unicodeScalars)
private let ellipsis: Unicode.Scalar = "…"

/// NFKC → 等价字符折叠 → 省略号折叠 → 去空白。
public func norm(_ text: String) -> String {
    let mapped = text.precomposedStringWithCompatibilityMapping.unicodeScalars.map { equivMap[$0] ?? $0 }
    var out = String.UnicodeScalarView()
    var i = 0
    while i < mapped.count {
        let c = mapped[i]
        if ellipsisRun.contains(c) {
            var j = i
            while j < mapped.count, ellipsisRun.contains(mapped[j]) { j += 1 }
            if j - i >= 2 { out.append(ellipsis); i = j; continue }
            out.append(ellipsisSingle.contains(c) ? ellipsis : c)
            i += 1
            continue
        }
        if !isPySpace(c) { out.append(c) }
        i += 1
    }
    return String(out)
}

/// Python len()：码点数。
@inlinable public func codePointCount(_ s: String) -> Int { s.unicodeScalars.count }

/// Python str.isspace() / 正则 `\\s`（str 模式）认的空白。比 Unicode White_Space 多 \\x1c-\\x1f。
public func isPySpace(_ c: Unicode.Scalar) -> Bool {
    switch c.value {
    case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A,
         0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
        return true
    default:
        return false
    }
}

/// Python str.strip()：去掉两端空白。
public func pyStrip(_ s: String) -> String {
    let u = Array(s.unicodeScalars)
    var a = 0, b = u.count
    while a < b, isPySpace(u[a]) { a += 1 }
    while b > a, isPySpace(u[b - 1]) { b -= 1 }
    var out = String.UnicodeScalarView()
    out.append(contentsOf: u[a..<b])
    return String(out)
}

/// Python 的字符串相等：逐码点比。Swift 的 `==` 按规范等价，会把不同码点序列判成相等。
@inlinable public func pyEq(_ a: String, _ b: String) -> Bool {
    a.unicodeScalars.elementsEqual(b.unicodeScalars)
}

/// Python round(x, n)：对 double 的精确值做十进制舍入，恰好一半时取偶。printf 系同样如此。
public func pyRound(_ x: Double, _ digits: Int) -> Double {
    Double(String(format: "%.\(digits)f", x)) ?? x
}
