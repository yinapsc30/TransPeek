import AppKit
import CoreGraphics

/// 被跟踪的目标窗口（design.md「WindowTracker」）。
struct TrackedWindow: Sendable, Equatable, Identifiable {
    let windowID: CGWindowID
    let pid: pid_t
    let bundleID: String
    let appName: String
    var title: String
    /// CG 全局坐标，原点在主屏左上角。
    var frame: CGRect
    var isOnScreen: Bool

    var id: CGWindowID { windowID }

    var displayTitle: String {
        title.isEmpty ? appName : "\(appName) — \(title)"
    }
}

enum WindowEvent: Sendable, Equatable {
    case moved(CGRect)
    /// 最小化、切换到其他桌面时为 `false`（R3.5、R12.3）。
    case visibilityChanged(Bool)
    /// 窗口已关闭（R3.6）。
    case closed
}

/// 以 30Hz 轮询 `CGWindowListCopyWindowInfo` 跟踪窗口位置和可见性，只在变化时发出事件。
/// 不需要辅助功能权限（R1.4），后续可替换为基于 AXObserver 的实现。
@MainActor
final class PollingWindowTracker {
    var onEvent: ((CGWindowID, WindowEvent) -> Void)?

    private struct State {
        var frame: CGRect
        var isOnScreen: Bool
    }

    private var tracked: [CGWindowID: State] = [:]
    private var timer: Timer?
    private let interval: TimeInterval

    init(interval: TimeInterval = 1.0 / 30.0) {
        self.interval = interval
    }

    func startTracking(_ window: TrackedWindow) {
        tracked[window.windowID] = State(frame: window.frame, isOnScreen: window.isOnScreen)
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // common 模式：菜单打开、拖动面板时也继续跟踪
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopTracking(_ windowID: CGWindowID) {
        tracked.removeValue(forKey: windowID)
        if tracked.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    /// 读取窗口当前状态，窗口不存在时返回 `nil`。
    static func snapshot(_ windowID: CGWindowID) -> (frame: CGRect, isOnScreen: Bool)? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }),
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return nil }
        let onScreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        return (frame, onScreen)
    }

    private func poll() {
        for (windowID, state) in tracked {
            guard let snapshot = Self.snapshot(windowID) else {
                tracked.removeValue(forKey: windowID)
                onEvent?(windowID, .closed)
                continue
            }
            if snapshot.isOnScreen != state.isOnScreen {
                tracked[windowID]?.isOnScreen = snapshot.isOnScreen
                onEvent?(windowID, .visibilityChanged(snapshot.isOnScreen))
            }
            if snapshot.frame != state.frame {
                tracked[windowID]?.frame = snapshot.frame
                onEvent?(windowID, .moved(snapshot.frame))
            }
        }
        if tracked.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }
}
