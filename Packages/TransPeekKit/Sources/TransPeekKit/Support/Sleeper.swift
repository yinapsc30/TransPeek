import Foundation

/// 可注入的等待实现，用于防抖、批量合并窗口和重试退避，测试时可替换。
public protocol Sleeper: Sendable {
    func sleep(for duration: Duration) async throws
}

/// 使用 `Task.sleep` 的真实实现，支持取消。
public struct TaskSleeper: Sleeper {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

extension Duration {
    /// 以秒为单位的浮点值。
    public var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
