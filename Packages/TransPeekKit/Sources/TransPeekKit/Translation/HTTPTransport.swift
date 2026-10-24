import Foundation

/// HTTP 发送接口，测试时替换为 mock。
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

/// 基于 URLSession 的实现。
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

enum HTTP {
    /// 发送 JSON 请求，把底层错误统一映射为 `TranslationError`。非 2xx 响应由 `mapStatus` 处理。
    static func sendJSON(
        _ request: URLRequest,
        transport: any HTTPTransport,
        mapStatus: (Int, String) -> TranslationError = { .http(status: $0, message: $1) }
    ) async throws -> Any {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw TranslationError.timeout
            case .cancelled: throw CancellationError()
            default: throw TranslationError.network(error.localizedDescription)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranslationError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranslationError.invalidResponse("不是 HTTP 响应")
        }
        guard (200...299).contains(http.statusCode) else {
            throw mapStatus(http.statusCode, errorMessage(from: data))
        }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TranslationError.invalidResponse("响应不是 JSON")
        }
    }

    /// 从错误响应中提取可读信息：`error.message`、`message` 或原始文本（截断）。
    static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let message = object["error"] as? String { return message }
            if let message = object["message"] as? String { return message }
        }
        let text = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "无详细信息" : text
    }

    static func jsonRequest(url: URL, body: [String: Any], headers: [String: String], timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }
}
