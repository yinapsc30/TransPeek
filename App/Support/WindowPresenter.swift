import AppKit
import SwiftUI

/// 管理设置、区域管理、窗口选择等普通窗口：同一个 id 只打开一个。
@MainActor
final class WindowPresenter {
    private var windows: [String: NSWindow] = [:]
    private var observers: [String: NSObjectProtocol] = [:]
    private var delegates: [String: CloseGuard] = [:]

    /// - Parameters:
    ///   - floating: 浮动层级，用于需要显示在游戏窗口之上的窗口（如框选后的区域配置）。
    ///   - minSize: 内容区域的最小尺寸。
    ///   - autosaveName: 记住窗口位置和大小。
    ///   - shouldClose: 用户点击关闭按钮时调用，返回 `false` 阻止关闭（例如有未保存的修改）。
    func show<Content: View>(
        id: String,
        title: String,
        size: CGSize,
        floating: Bool = false,
        resizable: Bool = true,
        minSize: CGSize? = nil,
        autosaveName: String? = nil,
        shouldClose: (() -> Bool)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        if let existing = windows[id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let controller = NSHostingController(rootView: content())
        // 可调整大小的窗口只采用视图的最小尺寸：含 ScrollView 的视图理想高度是全部内容的高度，
        // 跟随它会让窗口超出屏幕，底部按钮看不到（例如窗口选择列表）。固定大小的小窗口仍跟随内容。
        controller.sizingOptions = minSize != nil ? [] : (resizable ? [.minSize] : [.preferredContentSize])
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = resizable ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable]
        window.setContentSize(size)
        if let minSize { window.contentMinSize = minSize }
        window.isReleasedWhenClosed = false
        if floating {
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        if let autosaveName {
            window.setFrameAutosaveName(autosaveName)
            if !window.setFrameUsingName(autosaveName) { window.center() }
        } else {
            window.center()
        }
        if let shouldClose {
            let guardDelegate = CloseGuard(shouldClose: shouldClose)
            delegates[id] = guardDelegate
            window.delegate = guardDelegate
        }
        windows[id] = window
        observers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.forget(id) }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// 直接关闭，不经过 `shouldClose`。
    func close(_ id: String) {
        windows[id]?.close()
    }

    func isShowing(_ id: String) -> Bool {
        windows[id] != nil
    }

    private func forget(_ id: String) {
        windows.removeValue(forKey: id)
        delegates.removeValue(forKey: id)
        if let observer = observers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

private final class CloseGuard: NSObject, NSWindowDelegate {
    let shouldClose: () -> Bool

    init(shouldClose: @escaping () -> Bool) {
        self.shouldClose = shouldClose
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated { shouldClose() }
    }
}
