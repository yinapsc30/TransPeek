import Foundation
@testable import TransPeekKit

/// 记录请求并按脚本返回响应的 HTTP mock。
final class MockTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Int) throws -> (Int, Data)

    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let handler: Handler

    /// `handler` 的第二个参数是请求序号（从 0 开始）。
    init(handler: @escaping Handler) {
        self.handler = handler
    }

    convenience init(status: Int = 200, json: Any) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        self.init { _, _ in (status, data) }
    }

    var requests: [URLRequest] {
        lock.withLock { _requests }
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let index = lock.withLock { () -> Int in
            _requests.append(request)
            return _requests.count - 1
        }
        let (status, data) = try handler(request, index)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (data, response)
    }
}

extension URLRequest {
    var jsonBody: [String: Any] {
        guard let httpBody, let object = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any] else { return [:] }
        return object
    }
}

func jsonData(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

/// 返回 OpenAI 格式响应，`content` 为模型输出文本。
func openAIResponse(_ content: String) -> Data {
    jsonData(["choices": [["message": ["role": "assistant", "content": content]]]])
}

func translationsJSON(_ texts: [String]) -> String {
    let items = texts.enumerated().map { ["id": $0.offset + 1, "text": $0.element] as [String: Any] }
    return String(decoding: jsonData(["translations": items]), as: UTF8.self)
}
