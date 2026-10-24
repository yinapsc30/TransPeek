import Foundation

/// 等待画面稳定后再识别（R5.4）。纯状态机，时间由调用方传入（秒，单调递增）。
public struct StabilityGate: Sendable {
    public enum Decision: Sendable, Equatable {
        /// 与上次识别的画面相比没有变化。
        case idle
        /// 已发生变化，正在等待稳定。
        case waiting
        /// 应当识别：画面已稳定，或持续变化超过上限（`forced == true`）。
        case fire(forced: Bool)
    }

    /// 连续这么久没有变化视为稳定。
    public var stableDuration: TimeInterval
    /// 从第一次变化起超过这么久仍未稳定时，强制识别一次。
    public var maxWait: TimeInterval

    private var firstChange: TimeInterval?
    private var lastMotion: TimeInterval?
    /// 浮点比较容差，避免 0.25 秒的间隔因精度问题差一帧。
    private let epsilon = 0.001

    public init(stableDuration: TimeInterval = 0.25, maxWait: TimeInterval = 1.0) {
        self.stableDuration = stableDuration
        self.maxWait = maxWait
    }

    public var isWaiting: Bool { firstChange != nil }

    /// - Parameters:
    ///   - changedFromBaseline: 当前帧与上次识别时的画面相比是否有变化。
    ///   - movedSincePreviousFrame: 当前帧与上一帧相比是否有变化。
    ///   - now: 当前时间（秒）。
    public mutating func feed(changedFromBaseline: Bool, movedSincePreviousFrame: Bool, now: TimeInterval) -> Decision {
        guard let firstChange, let lastMotion else {
            guard changedFromBaseline else { return .idle }
            self.firstChange = now
            self.lastMotion = now
            return .waiting
        }

        var motion = lastMotion
        if movedSincePreviousFrame {
            motion = now
            self.lastMotion = now
        }

        if now - motion + epsilon >= stableDuration {
            reset()
            // 画面回到了上次识别时的样子（例如闪烁），不需要识别
            return changedFromBaseline ? .fire(forced: false) : .idle
        }
        if now - firstChange + epsilon >= maxWait {
            reset()
            return .fire(forced: true)
        }
        return .waiting
    }

    public mutating func reset() {
        firstChange = nil
        lastMotion = nil
    }
}
