// 书籍语言：Vision 的识别语言、融合打分、在线提示词都从这里取。
//
// 默认「中文（含英文）」与此前的行为完全一致（基准就是在它上面测的）。
// 西文书要单独选：
//   - Vision 换成对应语言，语言纠错才不会把法语、德语词当英语去「纠正」；
//   - 融合打分不再给含汉字的读法加分，也不把带重音的字母（é ü ß）算成噪声，
//     否则两引擎读法不同时会系统性地选去掉重音的那个；
//   - 在线读字和裁决的提示词写明语言，要求保留变音符号。
// PP-OCRv6 只有一套字典（含法德西意葡的重音字母），没有语言参数。

public struct BookLanguage: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let title: String
    /// VNRecognizeTextRequest.recognitionLanguages，按优先级
    public let vision: [String]
    /// 写进在线提示词的语言名；默认语言为 nil，提示词保持原样
    public let promptName: String?

    /// 西文书：融合打分按西文规则
    public var isLatin: Bool { id != "zh" }

    public static let all: [BookLanguage] = [
        BookLanguage(id: "zh", title: "中文（含英文）", vision: ["zh-Hans", "zh-Hant", "en-US"], promptName: nil),
        BookLanguage(id: "en", title: "英文", vision: ["en-US"], promptName: "英文"),
        BookLanguage(id: "fr", title: "法文", vision: ["fr-FR", "en-US"], promptName: "法文"),
        BookLanguage(id: "de", title: "德文", vision: ["de-DE", "en-US"], promptName: "德文"),
        BookLanguage(id: "es", title: "西班牙文", vision: ["es-ES", "en-US"], promptName: "西班牙文"),
        BookLanguage(id: "it", title: "意大利文", vision: ["it-IT", "en-US"], promptName: "意大利文"),
        BookLanguage(id: "pt", title: "葡萄牙文", vision: ["pt-BR", "en-US"], promptName: "葡萄牙文"),
    ]

    public static let `default` = all[0]

    public static func find(_ id: String?) -> BookLanguage? { all.first { $0.id == id } }

    /// 在线读字提示词的补充说明；默认语言返回空串
    public var transcribeHint: String {
        guard let n = promptName else { return "" }
        return "这一页是\(n)。按原文逐字转写，保留所有重音和变音符号（如 é è ç ü ö ß ñ），不要翻译成中文。"
    }

    /// 裁决提示词的补充说明；默认语言返回空串
    public var adjudicationHint: String {
        guard let n = promptName else { return "" }
        return "这本书是\(n)，几种读法的差别可能只在重音或变音符号上，按图或上下文选出拼写正确的一个。"
    }
}

/// 西文字母：拉丁字母补充、扩展 A/B、扩展附加区里的字母（× ÷ 不算）
@inlinable func isLatinExtendedLetter(_ c: Unicode.Scalar) -> Bool {
    let v = c.value
    if v == 0xD7 || v == 0xF7 { return false }
    return (0xC0...0x24F).contains(v) || (0x1E00...0x1EFF).contains(v)
}

/// 西文书常见、但中文书规则里没有的标点
let latinPunct = Set("«»‹›„‚¿¡".unicodeScalars)
