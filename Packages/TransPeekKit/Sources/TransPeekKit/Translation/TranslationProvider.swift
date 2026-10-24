import Foundation

/// LLM 请求附带的上下文：最近已翻译的条目（R16.9）。
public struct ContextPair: Sendable, Codable, Equatable {
    public let source: String
    public let translation: String

    public init(source: String, translation: String) {
        self.source = source
        self.translation = translation
    }
}

/// 一次批量翻译请求。
public struct TranslationRequest: Sendable, Equatable {
    public let texts: [String]
    /// `nil` 表示自动检测。
    public let source: Language?
    public let target: Language
    /// 仅 LLM 使用，Google 忽略。
    public let context: [ContextPair]
    public let appName: String
    /// 让模型标注每行的类型（ocr-cleanup C2.2），Google 忽略。
    public let classifiesLines: Bool

    public init(texts: [String], source: Language?, target: Language, context: [ContextPair] = [], appName: String = "", classifiesLines: Bool = false) {
        self.texts = texts
        self.source = source
        self.target = target
        self.context = context
        self.appName = appName
        self.classifiesLines = classifiesLines
    }
}

/// 翻译错误。
public enum TranslationError: Error, Sendable, Equatable, LocalizedError {
    /// 未配置 API Key 等，条目只显示原文（R8.3）。
    case notConfigured(String)
    case http(status: Int, message: String)
    /// 模型 ID 错误（服务商通常返回 400 或 404）。
    case modelNotFound(String)
    case timeout
    case network(String)
    case invalidResponse(String)

    /// 超时、网络错误、HTTP 408/429/5xx 可以重试（R8.6）。
    public var isRetryable: Bool {
        switch self {
        case .timeout, .network: true
        case let .http(status, _): status == 408 || status == 429 || (500...599).contains(status)
        case .notConfigured, .modelNotFound, .invalidResponse: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .notConfigured(reason): reason
        case let .http(status, message):
            switch status {
            case 401: "API Key 无效（401）：\(message)"
            case 403: "没有权限或额度不足（403）：\(message)"
            case 429: "请求过于频繁或额度不足（429）：\(message)"
            default: "HTTP \(status)：\(message)"
            }
        case let .modelNotFound(message): "请检查模型 ID：\(message)"
        case .timeout: "请求超时"
        case let .network(message): "网络错误：\(message)"
        case let .invalidResponse(message): "无法解析服务返回的结果：\(message)"
        }
    }
}

/// 一行的翻译结果（ocr-cleanup C2）。
public enum TranslationOutput: Sendable, Equatable {
    case translated(String)
    /// 智能整理判定为名字/时间行。
    case metadata
    /// 智能整理判定为界面文字。
    case hidden

    public var text: String? {
        if case let .translated(text) = self { return text }
        return nil
    }

    var state: TranslationState {
        switch self {
        case let .translated(text): .done(text)
        case .metadata: .metadata
        case .hidden: .hidden
        }
    }
}

/// 可替换的翻译服务接口（R8.7）。
public protocol TranslationProvider: Sendable {
    /// 影响译文的参数的哈希，用于缓存键（R8.4）。
    var fingerprint: String { get }

    /// 整个请求失败时抛出错误（会被重试）；单行失败放在对应位置的 `.failure` 中。
    /// 返回数组与 `request.texts` 一一对应。不支持智能整理的服务只返回 `.translated`。
    func translate(_ request: TranslationRequest) async throws -> [Result<TranslationOutput, TranslationError>]
}

/// 批量合并与并发策略（design.md「TranslationService」参数表）。
public struct BatchPolicy: Sendable, Equatable {
    public var window: Duration
    public var maxBatchSize: Int
    public var maxConcurrentRequests: Int

    public init(window: Duration, maxBatchSize: Int, maxConcurrentRequests: Int) {
        self.window = window
        self.maxBatchSize = maxBatchSize
        self.maxConcurrentRequests = maxConcurrentRequests
    }

    public static let google = BatchPolicy(window: .milliseconds(150), maxBatchSize: 100, maxConcurrentRequests: 4)
    public static let llm = BatchPolicy(window: .milliseconds(300), maxBatchSize: 20, maxConcurrentRequests: 2)
}
