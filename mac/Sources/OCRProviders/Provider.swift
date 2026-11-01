import Foundation

// 预置服务商。这只是可选列表：默认一家都不启用，用户亲自选中才生效。

public enum Dialect: String, Sendable, Codable {
    case openAICompatible, anthropic
}

public struct ProviderPreset: Sendable, Equatable {
    public let id: String, name: String, baseURL: String, dialect: Dialect
    /// 看图推荐模型，来自 P6 实测。nil 表示这家不推荐看图。
    public var recommendedVision: String? = nil
    /// 只用于纯文本裁决：P6 实测看图不稳定
    public var textOnly = false
    /// 纯文本裁决的推荐模型
    public var recommendedText: String? = nil
}

public enum ProviderPresets {
    public static let all = [
        ProviderPreset(id: "dashscope", name: "阿里云百炼", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", dialect: .openAICompatible, recommendedVision: "qwen3.7-flash"),
        ProviderPreset(id: "siliconflow", name: "硅基流动", baseURL: "https://api.siliconflow.cn/v1", dialect: .openAICompatible, recommendedVision: "Qwen/Qwen3-VL-32B-Instruct"),
        ProviderPreset(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", dialect: .openAICompatible, textOnly: true, recommendedText: "deepseek-flash"),
        ProviderPreset(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", dialect: .openAICompatible),
        ProviderPreset(id: "gemini", name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", dialect: .openAICompatible),
        ProviderPreset(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", dialect: .openAICompatible),
        ProviderPreset(id: "anthropic", name: "Anthropic", baseURL: "https://api.anthropic.com/v1", dialect: .anthropic),
    ]

    public static func find(_ id: String) -> ProviderPreset? { all.first { $0.id == id } }
}

public enum ModelStatus: String, Sendable {
    case recommended = "推荐", verified = "已验证可看图", unverified = "未验证", unsupported = "已测不支持看图"
}

public struct ModelOption: Sendable, Equatable, Identifiable {
    public let id: String, status: ModelStatus
}

public enum ModelFilter {
    /// /models 没有「能否看图」字段，只能靠名字排序。这些排到最后，但不隐藏：判断可能错，用户要能选到。
    static let notChat = ["embed", "rerank", "tts", "asr", "whisper", "speech", "audio", "voice", "sora", "wan2", "wanx", "dall-e",
                          "flux", "stable-diffusion", "kolors", "video", "translate", "moderation"]
    static let likelyVision = ["vl", "ocr", "vision", "vlm"]

    /// 全部列出，推荐和已验证排前面
    public static func options(ids: [String], profiles: [CapabilityProfile], recommended: String?) -> [ModelOption] {
        let probed = Dictionary(profiles.map { ($0.model, $0.supportsImage) }, uniquingKeysWith: { _, b in b })
        func rank(_ m: String) -> Int {
            let l = m.lowercased()
            if probed[m] == false { return 5 }
            if m == recommended { return 0 }
            if probed[m] == true { return 1 }
            if notChat.contains(where: { l.contains($0) }) { return 4 }
            return likelyVision.contains { l.contains($0) } ? 2 : 3
        }
        var all = Array(Set(ids))
        if let recommended, !all.contains(recommended) { all.append(recommended) }
        return all.sorted { (rank($0), $0) < (rank($1), $1) }.map { m in
            let st: ModelStatus = probed[m] == false ? .unsupported : (probed[m] == true ? .verified : (m == recommended ? .recommended : .unverified))
            return ModelOption(id: m, status: st)
        }
    }

    /// 搜索。搜索词和当前模型名是两回事：不能拿模型名去筛列表。
    public static func search(_ options: [ModelOption], _ query: String) -> [ModelOption] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? options : options.filter { $0.id.lowercased().contains(q) }
    }
}
