import Foundation

/// LLM 接口协议（R16.2）。
public enum LLMProtocol: String, Codable, Sendable, CaseIterable {
    case openAICompatible
    case anthropic

    public var displayName: String {
        switch self {
        case .openAICompatible: "OpenAI 兼容"
        case .anthropic: "Anthropic Messages"
        }
    }
}

/// 一个 LLM 翻译配置（R16.5）。API Key 不在此结构中，按配置 ID 保存在钥匙串（R16.13）。
public struct LLMConfig: Codable, Sendable, Hashable {
    public static let defaultTemperature = 0.2
    public static let defaultContextCount = 5
    public static let contextCountRange: ClosedRange<Int> = 0...20

    public var presetID: String
    public var protocolKind: LLMProtocol
    public var baseURL: URL
    public var model: String
    public var temperature: Double
    public var contextCount: Int
    /// `nil` 或空字符串表示使用内置模板。
    public var systemPrompt: String?
    /// JSON 对象字符串，浅合并到请求体（R16.10）。
    public var extraBody: String?
    public var fallbackToGoogle: Bool

    public init(
        presetID: String,
        protocolKind: LLMProtocol,
        baseURL: URL,
        model: String,
        temperature: Double = LLMConfig.defaultTemperature,
        contextCount: Int = LLMConfig.defaultContextCount,
        systemPrompt: String? = nil,
        extraBody: String? = nil,
        fallbackToGoogle: Bool = false
    ) {
        self.presetID = presetID
        self.protocolKind = protocolKind
        self.baseURL = baseURL
        self.model = model
        self.temperature = temperature
        self.contextCount = min(max(contextCount, Self.contextCountRange.lowerBound), Self.contextCountRange.upperBound)
        self.systemPrompt = systemPrompt
        self.extraBody = extraBody
        self.fallbackToGoogle = fallbackToGoogle
    }

    /// 实际使用的 system 提示词模板。
    public var effectiveSystemPrompt: String {
        if let systemPrompt, !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return systemPrompt
        }
        return PromptBuilder.defaultSystemPrompt
    }
}

/// 翻译配置（Google 或 LLM），可保存多个（R16.7）。
public struct TranslationProfile: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: Codable, Sendable, Hashable {
        case google
        case llm(LLMConfig)
    }

    public let id: UUID
    public var name: String
    public var kind: Kind

    public init(id: UUID = UUID(), name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public var llmConfig: LLMConfig? {
        if case let .llm(config) = kind { return config }
        return nil
    }

    public var isGoogle: Bool { kind == .google }

    /// 该配置的 API Key 在钥匙串中的账户名。Google 的 Key 全局共用。
    public var secretAccount: String {
        switch kind {
        case .google: SecretAccount.google
        case .llm: SecretAccount.llm(id)
        }
    }

    public static func defaultGoogle() -> TranslationProfile {
        TranslationProfile(name: "Google 翻译", kind: .google)
    }
}
