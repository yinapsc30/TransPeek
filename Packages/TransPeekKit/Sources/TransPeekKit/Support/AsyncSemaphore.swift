import Foundation

/// 简单的异步信号量，用于限制并发（OCR 全局并发、每个翻译配置的请求并发）。
public actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) {
        precondition(limit > 0)
        available = limit
    }

    public func wait() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func signal() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// 在信号量保护下执行操作。
    public func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await wait()
        defer { signal() }
        return try await operation()
    }
}
