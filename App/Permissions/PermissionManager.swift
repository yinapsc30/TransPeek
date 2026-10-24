import AppKit
import CoreGraphics
import Observation

/// 屏幕录制权限（R1）。MVP 只需要这一项权限（R1.4）。
@MainActor
@Observable
final class PermissionManager {
    private(set) var screenCaptureGranted: Bool
    /// 用户已打开过系统设置但权限仍未生效，通常需要重启应用（R1.2）。
    private(set) var mayNeedRestart = false
    /// 权限检查显示已授权，但实际截取失败。
    private(set) var captureFailedDespiteGrant = false

    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var openedSystemSettings = false

    init() {
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
        if openedSystemSettings && !screenCaptureGranted {
            mayNeedRestart = true
        }
    }

    /// 首次调用会弹出系统授权提示。
    func request() {
        _ = CGRequestScreenCaptureAccess()
        refresh()
    }

    func openSystemSettings() {
        openedSystemSettings = true
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func reportCaptureFailure() {
        if screenCaptureGranted { captureFailedDespiteGrant = true }
    }

    /// 重新启动应用，使新授予的权限生效。
    ///
    /// 先启动一个辅助进程，等当前进程完全退出后再打开应用，保证任何时候只有一个实例在运行。
    /// 应用路径通过参数传入（`$0`），不拼接进命令字符串。
    func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
            Bundle.main.bundlePath,
        ]
        do {
            try helper.run()
        } catch {
            return // 无法启动辅助进程时不退出，避免应用直接消失
        }
        NSApp.terminate(nil)
    }
}
