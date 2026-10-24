import Foundation

/// Google Cloud Translation Basic（v2）REST 接口（R8.1）。
public struct GoogleTranslateProvider: TranslationProvider {
    public static let endpoint = URL(string: "https://translation.googleapis.com/language/translate/v2")!

    private let apiKey: String?
    private let transport: any HTTPTransport
    private let endpoint: URL
    private let timeout: TimeInterval

    public init(
        apiKey: String?,
        transport: any HTTPTransport = URLSessionTransport(),
        endpoint: URL = GoogleTranslateProvider.endpoint,
        timeout: TimeInterval = 10
    ) {
        self.apiKey = apiKey
        self.transport = transport
        self.endpoint = endpoint
        self.timeout = timeout
    }

    public var fingerprint: String { "google-v2" }

    public func translate(_ request: TranslationRequest) async throws -> [Result<TranslationOutput, TranslationError>] {
        guard let apiKey, !apiKey.isEmpty else {
            throw TranslationError.notConfigured("未配置 Google API Key，请在设置中填写")
        }
        guard !request.texts.isEmpty else { return [] }

        var body: [String: Any] = [
            "q": request.texts,
            "target": request.target.code,
            "format": "text", // 避免返回 HTML 转义字符
        ]
        if let source = request.source {
            body["source"] = source.code // 自动检测时不传 source
        }
        // Key 放在请求头而不是 URL 中，避免出现在错误信息和日志里
        let urlRequest = try HTTP.jsonRequest(
            url: endpoint, body: body, headers: ["X-goog-api-key": apiKey], timeout: timeout
        )
        let json = try await HTTP.sendJSON(urlRequest, transport: transport)

        guard let data = (json as? [String: Any])?["data"] as? [String: Any],
              let translations = data["translations"] as? [[String: Any]]
        else { throw TranslationError.invalidResponse("缺少 data.translations") }
        guard translations.count == request.texts.count else {
            throw TranslationError.invalidResponse("返回条数与请求不一致")
        }
        return translations.map { item in
            if let text = item["translatedText"] as? String {
                .success(.translated(text))
            } else {
                .failure(.invalidResponse("缺少 translatedText"))
            }
        }
    }
}
