import Foundation

/// LLM 配置的保存前校验（R16.3、R16.4、R16.10）。
public enum LLMConfigValidator {
    public enum Issue: Error, Equatable, LocalizedError {
        case invalidURL
        case insecureRemoteURL
        case emptyModel
        case invalidExtraBody(String)

        public var errorDescription: String? {
            switch self {
            case .invalidURL: "Base URL 格式不正确，需要以 http:// 或 https:// 开头"
            case .insecureRemoteURL: "公网地址必须使用 https://，只有本机和局域网地址可以使用 http://"
            case .emptyModel: "请填写模型 ID"
            case let .invalidExtraBody(reason): "额外请求参数必须是 JSON 对象：\(reason)"
            }
        }
    }

    /// 校验 Base URL：本机、`.local` 和私有网段地址允许 http，其余必须是 https。
    public static func validateBaseURL(_ string: String) -> Result<URL, Issue> {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return .failure(.invalidURL) }
        if scheme == "http" && !isLocal(host: host) {
            return .failure(.insecureRemoteURL)
        }
        return .success(url)
    }

    public static func isLocal(host rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        if host == "::1" { return true }
        if host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") {
            return host.contains(":") // IPv6 链路本地和唯一本地地址
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (parts[0], parts[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    public static func validateModel(_ model: String) -> Result<String, Issue> {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .failure(.emptyModel) : .success(trimmed)
    }

    /// 额外请求参数必须是 JSON 对象；空字符串视为没有。
    public static func validateExtraBody(_ text: String?) -> Result<[String: Any]?, Issue> {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .success(nil) }
        do {
            let object = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            guard let dictionary = object as? [String: Any] else { return .failure(.invalidExtraBody("顶层不是对象")) }
            return .success(dictionary)
        } catch {
            return .failure(.invalidExtraBody("JSON 格式错误"))
        }
    }

    /// 校验整个配置，返回整理后的配置（去掉首尾空白）。
    public static func validate(_ config: LLMConfig, baseURLString: String) -> Result<LLMConfig, Issue> {
        var result = config
        switch validateBaseURL(baseURLString) {
        case let .success(url): result.baseURL = url
        case let .failure(issue): return .failure(issue)
        }
        switch validateModel(config.model) {
        case let .success(model): result.model = model
        case let .failure(issue): return .failure(issue)
        }
        if case let .failure(issue) = validateExtraBody(config.extraBody) {
            return .failure(issue)
        }
        return .success(result)
    }
}
