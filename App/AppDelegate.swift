import AppKit
import OSLog
import SwiftUI
import TransPeekKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: AppIdentity.subsystem, category: "app")
    private var services: AppServices!
    private var coordinator: SessionCoordinator!
    private var hotkeys: HotkeyManager!
    private var menuBarController: MenuBarController?
    /// 设置页共享的模型，设置窗口重新打开时复用。
    private lazy var settingsContext = SettingsContext(
        services: services,
        coordinator: coordinator,
        hotkeyConflicts: { [weak self] in self?.hotkeys.conflicts ?? [] },
        actions: .init(
            showPermissionGuide: { [weak self] in self?.showPermissionGuide() },
            showWindowPicker: { [weak self] in self?.showWindowPicker() },
            showRegionManager: { [weak self] in self?.showRegionManager() }
        )
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // 截图工具不读钥匙串：Debug 版每次编译签名都会变，读钥匙串会弹出授权框并阻塞
        services = DebugSnapshots.isRequested ? AppServices(secrets: InMemorySecretStore()) : AppServices()
        #else
        services = AppServices()
        #endif
        coordinator = SessionCoordinator(services: services)
        hotkeys = HotkeyManager()
        hotkeys.handler = { [weak self] action in self?.coordinator.handle(action) }
        hotkeys.registerAll()
        coordinator.onPermissionRequired = { [weak self] in self?.showPermissionGuide() }
        coordinator.onOpenTranslationSettings = { [weak self] in self?.showSettings(pane: .services) }

        menuBarController = MenuBarController(
            coordinator: coordinator,
            services: services,
            hotkeys: hotkeys,
            actions: .init(
                showWindowPicker: { [weak self] in self?.showWindowPicker() },
                showRegionManager: { [weak self] in self?.showRegionManager() },
                showSettings: { [weak self] in self?.showSettings() },
                // 菜单栏中的权限警告打开“开始使用”（S1.5）
                showPermissionGuide: { [weak self] in self?.showSettings(pane: .gettingStarted) }
            )
        )

        #if DEBUG
        if DebugSnapshots.runIfRequested(context: settingsContext) { return }
        #endif

        // 首次启动未授权时显示引导（R1.1）
        if !services.permissions.screenCaptureGranted {
            showPermissionGuide()
        }
        services.warmUpOCR()
        logger.info("TransPeek started")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 退出前写入防抖中的预设。
        // 不能返回 terminateLater 再用 MainActor 的 Task 回复：terminate 在主队列的回调里被调用时
        // （例如“重启”），主队列被占用，Task 永远得不到执行，应用会卡在退出中。
        // 这里在后台执行写入，主线程最多同步等待 2 秒。
        let store = services.presetStore
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await store.flush()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 2) == .timedOut {
            logger.error("Timed out flushing presets before quit")
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys?.unregisterAll()
        coordinator?.endSession()
    }

    // MARK: - 窗口

    private func showWindowPicker() {
        let presenter = services.presenter
        presenter.show(id: "window-picker", title: "选择目标窗口", size: CGSize(width: 680, height: 520)) {
            WindowPickerView(
                onSelect: { [weak self] window in
                    presenter.close("window-picker")
                    Task { await self?.coordinator.selectTarget(window) }
                },
                onCancel: { presenter.close("window-picker") }
            )
        }
    }

    private func showRegionManager() {
        let coordinator = self.coordinator!
        let profiles = services.profiles
        services.presenter.show(id: "region-manager", title: "管理区域", size: CGSize(width: 720, height: 500)) {
            RegionManagerView(coordinator: coordinator, profiles: profiles)
        }
    }

    /// 打开设置窗口；指定页面时切换到该页面（S1.5）。
    private func showSettings(pane: SettingsPane? = nil) {
        let context = settingsContext
        let presenter = services.presenter
        if let pane { context.router.select(pane) }
        presenter.show(
            id: "settings",
            title: "TransPeek 设置",
            size: CGSize(width: 900, height: 640),
            minSize: CGSize(width: 820, height: 560),
            autosaveName: "TransPeekSettings",
            shouldClose: { context.router.requestClose { presenter.close("settings") } }
        ) {
            SettingsRootView(context: context)
        }
    }

    private func showPermissionGuide() {
        let permissions = services.permissions
        services.presenter.show(id: "permission-guide", title: "TransPeek 权限", size: CGSize(width: 480, height: 320), resizable: false) {
            PermissionGuideView(permissions: permissions)
        }
    }
}
