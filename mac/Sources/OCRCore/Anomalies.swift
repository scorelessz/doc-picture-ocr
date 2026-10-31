// src/postcheck.py detect_anomalies 与 src/book_fuse.py 打分辅助的移植。
// 融合只用到「命中几条」，所以这里只返回计数，不返回描述文字。

let bracketPairs: [Unicode.Scalar: Unicode.Scalar] = [
    "（": "）", "〔": "〕", "【": "】", "｛": "｝", "［": "］",
    "《": "》", "〈": "〉", "「": "」", "『": "』", "(": ")", "[": "]", "{": "}",
]
let bracketClosers = Set(bracketPairs.values)

/// postcheck 的 CJK 只认基本区 一-鿿。
@inlinable func isBasicCJK(_ c: Unicode.Scalar) -> Bool { (0x4E00...0x9FFF).contains(c.value) }

/// book_fuse 的 _CJK 还包括扩展 A 区。
@inlinable func isCJK(_ c: Unicode.Scalar) -> Bool {
    (0x4E00...0x9FFF).contains(c.value) || (0x3400...0x4DBF).contains(c.value)
}

private func isASCIIAlnum(_ c: Unicode.Scalar) -> Bool {
    ("0"..."9").contains(c) || ("A"..."Z").contains(c) || ("a"..."z").contains(c)
}

private let halfPunct = Set(",;:?!".unicodeScalars)

/// detect_anomalies 命中条数：
///   (a) 夹在中文之间的单个数字/字母；(b) 行内括号跨家族；(c) 夹在中文之间的半角标点。
public func anomalyCount(_ text: String) -> Int {
    let s = Array(text.unicodeScalars)
    var n = 0
    if s.count >= 3 {
        for i in 1..<(s.count - 1) where isBasicCJK(s[i - 1]) && isBasicCJK(s[i + 1]) {
            if isASCIIAlnum(s[i]) || halfPunct.contains(s[i]) { n += 1 }
        }
    }
    var stack: [Unicode.Scalar] = []
    for ch in s {
        if bracketPairs[ch] != nil {
            stack.append(ch)
        } else if bracketClosers.contains(ch), let op = stack.popLast(), bracketPairs[op] != ch {
            n += 1
        }
    }
    return n
}

/// 行内未闭合的左括号 + 多余的右括号。
func bracketDefects(_ text: String) -> Int {
    var stack = 0, extra = 0
    for ch in text.unicodeScalars {
        if bracketPairs[ch] != nil {
            stack += 1
        } else if bracketClosers.contains(ch) {
            if stack > 0 { stack -= 1 } else { extra += 1 }
        }
    }
    return stack + extra
}

private let plausibleExtra = Set(
    ("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
     + "·—–‒…‘’“”、。，！？；：（）《》〈〉「」『』【】〔〕"
     + ".,;:!?'\"()[]{}<>/\\-+=%&#@*~^_|§¶†‡°±×÷").unicodeScalars)

/// 中文书里「正常」会出现的字符；其余（替换符、私用区、乱码符号）按噪声计。
func isPlausible(_ c: Unicode.Scalar) -> Bool {
    let v = c.value
    return isCJK(c) || (0x3000...0x303F).contains(v) || (0xFF00...0xFFEF).contains(v)
        || isPySpace(c) || plausibleExtra.contains(c)
}

func noiseCount(_ text: String) -> Int {
    text.unicodeScalars.reduce(0) { $0 + (isPlausible($1) ? 0 : 1) }
}

func cjkRatio(_ text: String) -> Double {
    let core = text.unicodeScalars.filter { !isPySpace($0) }
    guard !core.isEmpty else { return 0 }
    return Double(core.filter(isCJK).count) / Double(core.count)
}
