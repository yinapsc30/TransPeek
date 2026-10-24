import Foundation
@testable import TransPeekKit

/// 每个测试使用独立的临时目录。
func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("TransPeekKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func roundTrip<T: Codable>(_ value: T) throws -> T {
    let data = try JSONCoding.encoder().encode(value)
    return try JSONCoding.decoder().decode(T.self, from: data)
}

/// 测试中用字符串字面量表示 `.translated(...)`，让断言更简洁。
extension TranslationOutput: ExpressibleByStringInterpolation {
    public init(stringLiteral value: String) {
        self = .translated(value)
    }
}

/// 立即返回并记录每次等待时长的 Sleeper，用于重试退避测试。
final class RecordingSleeper: Sleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var _durations: [Duration] = []

    var durations: [Duration] {
        lock.withLock { _durations }
    }

    func sleep(for duration: Duration) async throws {
        lock.withLock { _durations.append(duration) }
        try Task.checkCancellation()
    }
}
