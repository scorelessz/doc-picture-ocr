import Foundation

// 预置服务商。这只是可选列表：默认一家都不启用，用户亲自选中才生效。

public enum Dialect: String, Sendable, Codable {
    case openAICompatible, anthropic
}

public struct ProviderPreset: Sendable, Equatable {
    public let id: String, name: String, baseURL: String, dialect: Dialect
}

public enum ProviderPresets {
    public static let all = [
        ProviderPreset(id: "dashscope", name: "阿里云百炼", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", dialect: .openAICompatible),
        ProviderPreset(id: "siliconflow", name: "硅基流动", baseURL: "https://api.siliconflow.cn/v1", dialect: .openAICompatible),
        ProviderPreset(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", dialect: .openAICompatible),
        ProviderPreset(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", dialect: .openAICompatible),
        ProviderPreset(id: "gemini", name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", dialect: .openAICompatible),
        ProviderPreset(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", dialect: .openAICompatible),
        ProviderPreset(id: "anthropic", name: "Anthropic", baseURL: "https://api.anthropic.com/v1", dialect: .anthropic),
    ]

    public static func find(_ id: String) -> ProviderPreset? { all.first { $0.id == id } }
}
