import Foundation

/// 翻译服务编辑页的草稿（S7）。值类型，便于测试脏状态和逐项校验。
public struct ProfileDraft: Sendable, Equatable {
    public enum Field: Hashable, Sendable {
        case name, baseURL, model, extraBody
    }

    public let id: UUID
    public let isGoogle: Bool
    public var name: String
    public var presetID: String
    public var protocolKind: LLMProtocol
    public var baseURL: String
    public var model: String
    public var temperature: Double
    public var contextCount: Int
    public var systemPrompt: String
    public var extraBody: String
    public var fallbackToGoogle: Bool
    public var apiKey: String

    /// 编辑开始时的值；新配置为 `nil`，此时始终视为有修改。
    public private(set) var original: Snapshot?

    public struct Snapshot: Sendable, Equatable {
        let name: String, presetID: String, protocolKind: LLMProtocol, baseURL: String, model: String
        let temperature: Double, contextCount: Int, systemPrompt: String, extraBody: String
        let fallbackToGoogle: Bool, apiKey: String
    }

    /// - Parameters:
    ///   - isNew: 尚未保存的新配置。
    public init(profile: TranslationProfile, apiKey: String, isNew: Bool) {
        id = profile.id
        isGoogle = profile.isGoogle
        name = profile.name
        self.apiKey = apiKey
        if let config = profile.llmConfig {
            presetID = config.presetID
            protocolKind = config.protocolKind
            let url = config.baseURL.absoluteString
            baseURL = url == "https://" || url == "https:" ? "" : url
            model = config.model
            temperature = config.temperature
            contextCount = config.contextCount
            systemPrompt = config.systemPrompt ?? ""
            extraBody = config.extraBody ?? ""
            fallbackToGoogle = config.fallbackToGoogle
        } else {
            presetID = "google"
            protocolKind = .openAICompatible
            baseURL = ""
            model = ""
            temperature = LLMConfig.defaultTemperature
            contextCount = LLMConfig.defaultContextCount
            systemPrompt = ""
            extraBody = ""
            fallbackToGoogle = false
        }
        original = isNew ? nil : snapshot
    }

    private var snapshot: Snapshot {
        Snapshot(
            name: name, presetID: presetID, protocolKind: protocolKind, baseURL: baseURL, model: model,
            temperature: temperature, contextCount: contextCount, systemPrompt: systemPrompt, extraBody: extraBody,
            fallbackToGoogle: fallbackToGoogle, apiKey: apiKey
        )
    }

    public var isNew: Bool { original == nil }

    /// 有未保存的修改（S7.7）。
    public var isDirty: Bool { original != snapshot }

    /// 逐项校验结果，键为出错的字段（S7.4）。
    public var issues: [Field: String] {
        var result: [Field: String] = [:]
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result[.name] = "请填写名称"
        }
        guard !isGoogle else { return result }
        if case let .failure(issue) = LLMConfigValidator.validateBaseURL(baseURL) {
            result[.baseURL] = issue.localizedDescription
        }
        if case let .failure(issue) = LLMConfigValidator.validateModel(model) {
            result[.model] = issue.localizedDescription
        }
        if case let .failure(issue) = LLMConfigValidator.validateExtraBody(extraBody) {
            result[.extraBody] = issue.localizedDescription
        }
        return result
    }

    public var canSave: Bool { isDirty && issues.isEmpty }

    /// 生成配置；有校验错误时返回 `nil`。
    public func makeProfile() -> TranslationProfile? {
        guard issues.isEmpty else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if isGoogle {
            return TranslationProfile(id: id, name: trimmedName, kind: .google)
        }
        guard case let .success(url) = LLMConfigValidator.validateBaseURL(baseURL),
              case let .success(model) = LLMConfigValidator.validateModel(model)
        else { return nil }
        let prompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let extra = extraBody.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranslationProfile(id: id, name: trimmedName, kind: .llm(LLMConfig(
            presetID: presetID,
            protocolKind: protocolKind,
            baseURL: url,
            model: model,
            temperature: temperature,
            contextCount: contextCount,
            systemPrompt: prompt.isEmpty ? nil : systemPrompt,
            extraBody: extra.isEmpty ? nil : extraBody,
            fallbackToGoogle: fallbackToGoogle
        )))
    }

    /// 保存成功后把当前值作为新的原值。
    public mutating func markSaved() {
        original = snapshot
    }

    /// 还原到编辑开始时的值（S7.7）。
    public mutating func revert() {
        guard let original else { return }
        name = original.name
        presetID = original.presetID
        protocolKind = original.protocolKind
        baseURL = original.baseURL
        model = original.model
        temperature = original.temperature
        contextCount = original.contextCount
        systemPrompt = original.systemPrompt
        extraBody = original.extraBody
        fallbackToGoogle = original.fallbackToGoogle
        apiKey = original.apiKey
    }

    /// 切换服务商时填充协议和 Base URL（R16.1）。
    public mutating func applyPreset(_ preset: LLMPreset) {
        presetID = preset.id
        protocolKind = preset.protocol
        baseURL = preset.baseURL
    }
}
