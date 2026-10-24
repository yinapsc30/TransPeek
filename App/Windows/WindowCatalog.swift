import AppKit
import ScreenCaptureKit

/// 列出可截取的窗口、找前台窗口、生成缩略图（R3.1、R3.2）。
enum WindowCatalog {
    static let minimumSize = CGSize(width: 120, height: 80)

    /// 当前所有可截取的应用窗口，排除 TransPeek 自身（R3.1）。
    static func candidates() async throws -> [TrackedWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownBundleID = Bundle.main.bundleIdentifier
        return content.windows.compactMap { window -> TrackedWindow? in
            guard window.windowLayer == 0,
                  window.frame.width >= minimumSize.width, window.frame.height >= minimumSize.height,
                  let app = window.owningApplication,
                  app.bundleIdentifier != ownBundleID,
                  !app.bundleIdentifier.isEmpty
            else { return nil }
            return TrackedWindow(
                windowID: window.windowID,
                pid: app.processID,
                bundleID: app.bundleIdentifier,
                appName: app.applicationName,
                title: window.title ?? "",
                frame: window.frame,
                isOnScreen: window.isOnScreen
            )
        }
        .sorted { ($0.appName, $0.title) < ($1.appName, $1.title) }
    }

    /// 前台应用最前面的窗口（R3.2）。`CGWindowListCopyWindowInfo` 的结果按从前到后排序。
    @MainActor
    static func frontmostWindow() -> TrackedWindow? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ownPID,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  frame.width >= minimumSize.width, frame.height >= minimumSize.height
            else { continue }
            return TrackedWindow(
                windowID: number,
                pid: app.processIdentifier,
                bundleID: app.bundleIdentifier ?? "pid.\(app.processIdentifier)",
                appName: app.localizedName ?? "未知应用",
                title: info[kCGWindowName as String] as? String ?? "",
                frame: frame,
                isOnScreen: true
            )
        }
        return nil
    }

    static func scWindow(_ windowID: CGWindowID) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        return content.windows.first { $0.windowID == windowID }
    }

    /// 窗口缩略图，失败时返回 `nil`。
    static func thumbnail(_ windowID: CGWindowID, maxWidth: CGFloat = 320) async -> CGImage? {
        guard let window = try? await scWindow(windowID), window.frame.width > 0 else { return nil }
        let scale = min(1, maxWidth / window.frame.width) * 2
        let configuration = SCStreamConfiguration()
        configuration.width = max(2, Int(window.frame.width * scale))
        configuration.height = max(2, Int(window.frame.height * scale))
        configuration.showsCursor = false
        return try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration
        )
    }
}
