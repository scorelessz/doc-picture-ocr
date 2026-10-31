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
        if !c.properties.isWhitespace { out.append(c) }
        i += 1
    }
    return String(out)
}

/// Python len()：码点数。
@inlinable public func codePointCount(_ s: String) -> Int { s.unicodeScalars.count }

/// Python str.strip()：去掉两端空白。
public func pyStrip(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines)
}
