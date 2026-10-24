import Foundation

/// 一次 LLM 补全调用的参数。
public struct LLMCompletionRequest: Sendable, Equatable {
    public let system: String
    public let user: String
    public let maxTokens: Int
    public let jsonMode: Bool

    public init(system: String, user: String, maxTokens: Int, jsonMode: Bool) {
        self.system = system
        self.user = user
        self.maxTokens = maxTokens
        self.jsonMode = jsonMode
    }
}

/// LLM 接口协议的客户端（R16.2）。
public protocol LLMClient: Sendable {
    func complete(_ request: LLMCompletionRequest) async throws -> String
}

enum LLMRequestBody {
    /// 把额外请求参数浅合并到请求体，用户参数优先；值为 `null` 时删除该参数（R16.10）。
    static func merge(_ body: [String: Any], extra: String?) -> [String: Any] {
        guard case let .success(extraObject?) = LLMConfigValidator.validateExtraBody(extra) else { return body }
        var merged = body
        for (key, value) in extraObject {
            if value is NSNull {
                merged.removeValue(forKey: key)
            } else {
                merged[key] = value
            }
        }
        return merged
    }

    /// 400/404 且错误信息提到 model 时，提示检查模型 ID。
    static func mapStatus(_ status: Int, _ message: String) -> TranslationError {
        if status == 400 || status == 404, message.range(of: "model", options: .caseInsensitive) != nil {
            return .modelNotFound(message)
        }
        if status == 404 {
            return .http(status: status, message: "\(message)（请检查 Base URL 和模型 ID）")
        }
        return .http(status: status, message: message)
    }
}

/// OpenAI 兼容的 Chat Completions 接口：`POST {baseURL}/chat/completions`。
public struct OpenAICompatibleClient: LLMClient {
    private let config: LLMConfig
    private let apiKey: String?
    private let transport: any HTTPTransport
    private let timeout: TimeInterval

    public init(config: LLMConfig, apiKey: String?, transport: any HTTPTransport = URLSessionTransport(), timeout: TimeInterval = 30) {
        self.config = config
        self.apiKey = apiKey
        self.transport = transport
        self.timeout = timeout
    }

    public func complete(_ request: LLMCompletionRequest) async throws -> String {
        var body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": request.system],
                ["role": "user", "content": request.user],
            ],
            "temperature": config.temperature,
            "max_tokens": request.maxTokens,
            "stream": false,
        ]
        if request.jsonMode {
            body["response_format"] = ["type": "json_object"]
        }
        var headers: [String: String] = [:]
        if let apiKey, !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        let urlRequest = try HTTP.jsonRequest(
            url: config.baseURL.appendingPathComponent("chat/completions"),
            body: LLMRequestBody.merge(body, extra: config.extraBody),
            headers: headers,
            timeout: timeout
        )
        let json = try await HTTP.sendJSON(urlRequest, transport: transport, mapStatus: LLMRequestBody.mapStatus)

        guard let choices = (json as? [String: Any])?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any]
        else { throw TranslationError.invalidResponse("缺少 choices[0].message") }
        if let content = message["content"] as? String {
            return content
        }
        // 部分服务返回内容分段数组
        if let parts = message["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined()
        }
        throw TranslationError.invalidResponse("缺少 message.content")
    }
}

/// Anthropic Messages 接口：`POST {baseURL}/v1/messages`。
public struct AnthropicClient: LLMClient {
    public static let apiVersion = "2023-06-01"

    private let config: LLMConfig
    private let apiKey: String?
    private let transport: any HTTPTransport
    private let timeout: TimeInterval

    public init(config: LLMConfig, apiKey: String?, transport: any HTTPTransport = URLSessionTransport(), timeout: TimeInterval = 30) {
        self.config = config
        self.apiKey = apiKey
        self.transport = transport
        self.timeout = timeout
    }

    public func complete(_ request: LLMCompletionRequest) async throws -> String {
        let body: [String: Any] = [
            "model": config.model,
            "system": request.system,
            "messages": [["role": "user", "content": request.user]],
            "temperature": config.temperature,
            "max_tokens": request.maxTokens,
        ]
        var headers = ["anthropic-version": Self.apiVersion]
        if let apiKey, !apiKey.isEmpty {
            headers["x-api-key"] = apiKey
        }
        let urlRequest = try HTTP.jsonRequest(
            url: config.baseURL.appendingPathComponent("v1/messages"),
            body: LLMRequestBody.merge(body, extra: config.extraBody),
            headers: headers,
            timeout: timeout
        )
        let json = try await HTTP.sendJSON(urlRequest, transport: transport, mapStatus: LLMRequestBody.mapStatus)

        guard let content = (json as? [String: Any])?["content"] as? [[String: Any]] else {
            throw TranslationError.invalidResponse("缺少 content")
        }
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw TranslationError.invalidResponse("content 中没有文本") }
        return text
    }
}
