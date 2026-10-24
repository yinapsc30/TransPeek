import AppKit
import TransPeekKit

/// 菜单栏图标和菜单（R2.1、R2.2、R2.4、R1.3）。菜单在每次打开时按当前状态重建。
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let coordinator: SessionCoordinator
    private let services: AppServices
    private let hotkeys: HotkeyManager
    private let actions: Actions

    struct Actions {
        let showWindowPicker: () -> Void
        let showRegionManager: () -> Void
        let showSettings: () -> Void
        let showPermissionGuide: () -> Void
    }

    init(coordinator: SessionCoordinator, services: AppServices, hotkeys: HotkeyManager, actions: Actions) {
        self.coordinator = coordinator
        self.services = services
        self.hotkeys = hotkeys
        self.actions = actions
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "TransPeek")
            image?.isTemplate = true // 跟随菜单栏的深色/浅色外观
            button.image = image
            button.toolTip = "TransPeek"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        services.permissions.refresh()
        let granted = services.permissions.screenCaptureGranted

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        menu.addItem(disabled("TransPeek \(version)"))

        // 状态与警告
        if let target = coordinator.target {
            let suffix = coordinator.isTargetClosed ? "（已关闭）" : (target.isOnScreen ? "" : "（不可见）")
            menu.addItem(disabled("目标：\(target.displayTitle)\(suffix)", truncateTo: 48))
        } else {
            menu.addItem(disabled("未选择目标窗口"))
        }
        if !granted {
            menu.addItem(item("⚠️ 未授予屏幕录制权限…", action: #selector(showPermissionGuide)))
        }
        if !hotkeys.conflicts.isEmpty {
            let names = hotkeys.conflicts.map(\.shortcutLabel).joined(separator: "、")
            menu.addItem(disabled("⚠️ 快捷键冲突：\(names)"))
        }
        if coordinator.presetRecovered {
            menu.addItem(disabled("⚠️ 预设文件损坏，已备份并重置"))
        }
        if let error = coordinator.lastError {
            menu.addItem(disabled("⚠️ \(error)", truncateTo: 60))
        }
        menu.addItem(.separator())

        menu.addItem(item("选择目标窗口…", action: #selector(showWindowPicker), enabled: granted))
        menu.addItem(item("框选区域", action: #selector(selectRegion), hotkey: .selectRegion, enabled: granted))
        menu.addItem(item("重新识别单次区域", action: #selector(rerunOnce), hotkey: .rerunOnce, enabled: granted && coordinator.hasOnceRegions))
        menu.addItem(item(coordinator.allPaused ? "恢复全部" : "暂停全部", action: #selector(togglePause), hotkey: .togglePause, enabled: !coordinator.regions.isEmpty))
        menu.addItem(item(coordinator.allLocked ? "解锁面板" : "锁定面板", action: #selector(toggleLock), hotkey: .toggleLock, enabled: !coordinator.regions.isEmpty))
        menu.addItem(item("管理区域…", action: #selector(showRegionManager)))
        if coordinator.target != nil {
            menu.addItem(item("结束当前会话", action: #selector(endSession)))
        }
        menu.addItem(.separator())
        menu.addItem(item("设置…", action: #selector(showSettings), key: ","))
        menu.addItem(item("退出 TransPeek", action: #selector(quit), key: "q"))
    }

    private func item(_ title: String, action: Selector, hotkey: HotkeyAction? = nil, key: String = "", enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: hotkey?.keyEquivalent ?? key)
        if hotkey != nil { item.keyEquivalentModifierMask = [.control, .option] }
        item.target = self
        item.isEnabled = enabled
        return item
    }

    private func disabled(_ title: String, truncateTo limit: Int = 80) -> NSMenuItem {
        let text = title.count > limit ? String(title.prefix(limit)) + "…" : title
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = title
        return item
    }

    @objc private func showWindowPicker() { actions.showWindowPicker() }
    @objc private func showRegionManager() { actions.showRegionManager() }
    @objc private func showSettings() { actions.showSettings() }
    @objc private func showPermissionGuide() { actions.showPermissionGuide() }
    @objc private func selectRegion() { coordinator.handle(.selectRegion) }
    @objc private func rerunOnce() { coordinator.handle(.rerunOnce) }
    @objc private func togglePause() { coordinator.handle(.togglePause) }
    @objc private func toggleLock() { coordinator.handle(.toggleLock) }
    @objc private func endSession() { coordinator.endSession() }
    @objc private func quit() { NSApp.terminate(nil) }
}
