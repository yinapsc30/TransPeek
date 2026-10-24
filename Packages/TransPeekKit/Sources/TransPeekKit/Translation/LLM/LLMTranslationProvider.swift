import CryptoKit
import Foundation

/// 基于 LLM 的翻译（R16）。负责提示词组装和结果解析，具体接口协议由 `LLMClient` 处理。
public struct LLMTranslationProvider: TranslationProvider {
    private let config: LLMConfig
    private let client: any LLMClient
    private let jsonMode: Bool
    private let missingKeyReason: String?

    /// - Parameter missingKeyReason: 预设要求 Key 但未填写时的提示，非空时直接返回未配置。
    public init(config: LLMConfig, client: any LLMClient, jsonMode: Bool, missingKeyReason: String? = nil) {
        self.config = config
        self.client = client
        self.jsonMode = jsonMode
        self.missingKeyReason = missingKeyReason
    }

    /// SHA-256（协议 + Base URL + 模型 + 温度 + system 提示词 + 额外请求参数）的前 16 位十六进制字符。
    public var fingerprint: String {
        Self.fingerprint(for: config)
    }

    public static func fingerprint(for config: LLMConfig) -> String {
        let parts = [
            config.protocolKind.rawValue,
            config.baseURL.absoluteString,
            config.model,
            String(format: "%.3f", config.temperature),
            config.effectiveSystemPrompt,
            config.extraBody?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
        ]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return "llm-" + digest.map { String(format: "%02x", $0) }.joined().prefix(16)
    }

    public func translate(_ request: TranslationRequest) async throws -> [Result<TranslationOutput, TranslationError>] {
        if let missingKeyReason {
            throw TranslationError.notConfigured(missingKeyReason)
        }
        guard !request.texts.isEmpty else { return [] }

        // 自定义提示词也会追加输出格式，保证结果可以解析（C2.6）
        let system = PromptBuilder.fullSystem(
            template: config.effectiveSystemPrompt,
            source: request.source, target: request.target, appName: request.appName,
            classifiesLines: request.classifiesLines
        )
        let raw = try await client.complete(completion(system: system, lines: request.texts, context: request.context))
        let parsed = ResponseParser.parseOutputs(raw, count: request.texts.count)

        var results: [Result<TranslationOutput, TranslationError>] = []
        for (index, text) in request.texts.enumerated() {
            if let output = parsed[index + 1] {
                results.append(.success(output))
                continue
            }
            // 缺失、多出或无法解析的行，逐行再请求一次
            do {
                let single = try await client.complete(completion(system: system, lines: [text], context: request.context))
                if let output = ResponseParser.parseOutputs(single, count: 1)[1] {
                    results.append(.success(output))
                } else {
                    results.append(.failure(.invalidResponse("模型没有按要求返回 JSON")))
                }
            } catch let error as TranslationError {
                results.append(.failure(error))
            }
        }
        return results
    }

    private func completion(system: String, lines: [String], context: [ContextPair]) -> LLMCompletionRequest {
        LLMCompletionRequest(
            system: system,
            user: PromptBuilder.user(lines: lines, context: context, contextLimit: config.contextCount),
            maxTokens: PromptBuilder.maxTokens(for: lines),
            jsonMode: jsonMode
        )
    }
}
