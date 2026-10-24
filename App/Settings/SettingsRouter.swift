import Observation
import SwiftUI
import TransPeekKit

/// 设置窗口的页面（S1.1）。
enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case gettingStarted, general, recognition, panel, services, hotkeys, privacy, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gettingStarted: "开始使用"
        case .general: "通用"
        case .recognition: "识别"
        case .panel: "面板"
        case .services: "翻译服务"
        case .hotkeys: "快捷键"
        case .privacy: "隐私与数据"
        case .about: "关于"
        }
    }

    var subtitle: String {
        switch self {
        case .gettingStarted: "完成下面三步就可以开始翻译。"
        case .general: "默认语言和启动方式。"
        case .recognition: "截取频率和文字识别的灵敏度。"
        case .panel: "新建区域时面板使用的默认样式。"
        case .services: "可以保存多个配置，每个区域可以单独选择。标记“默认”的配置用于未单独指定的区域。"
        case .hotkeys: "全局快捷键在任何应用中都可以使用，包括全屏游戏。"
        case .privacy: "TransPeek 处理哪些数据，以及保存在哪里。"
        case .about: ""
        }
    }

    var symbol: String {
        switch self {
        case .gettingStarted: "checkmark.seal.fill"
        case .general: "gearshape.fill"
        case .recognition: "text.viewfinder"
        case .panel: "sidebar.right"
        case .services: "character.bubble.fill"
        case .hotkeys: "command"
        case .privacy: "hand.raised.fill"
        case .about: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .gettingStarted: .green
        case .general: .gray
        case .recognition: .indigo
        case .panel: .blue
        case .services: .teal
        case .hotkeys: .orange
        case .privacy: .cyan
        case .about: Color(nsColor: .systemGray)
        }
    }
}

/// 翻译服务页内的导航。
enum ServiceRoute: Hashable {
    case existing(UUID)
    /// 尚未保存的新配置，`apiKey` 用于“复制为新配置”。
    case new(TranslationProfile, apiKey: String)
}

/// 当前页面、翻译服务页内的导航，以及未保存修改的拦截（S1.2、S1.5、S7.8）。
@MainActor
@Observable
final class SettingsRouter {
    private static let lastPaneKey = "settings.lastPane"

    var pane: SettingsPane {
        didSet { UserDefaults.standard.set(pane.rawValue, forKey: Self.lastPaneKey) }
    }
    private(set) var serviceRoute: ServiceRoute?
    /// 非空时显示“是否保存修改”的提示。
    var pendingAction: PendingAction?

    struct PendingAction: Identifiable {
        let id = UUID()
        let perform: () -> Void
    }

    /// 当前编辑页注册的拦截。用 token 区分，避免旧页面消失时清掉新页面的注册。
    @ObservationIgnored private var guardToken: UUID?
    @ObservationIgnored private var hasUnsavedChanges: () -> Bool = { false }
    @ObservationIgnored private var saveChanges: () -> Bool = { true }

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.lastPaneKey).flatMap(SettingsPane.init(rawValue:))
        pane = saved ?? .gettingStarted
    }

    // MARK: - 导航

    func select(_ pane: SettingsPane) {
        guard pane != self.pane || serviceRoute != nil else { return }
        navigate {
            self.serviceRoute = nil
            self.pane = pane
        }
    }

    func openService(_ route: ServiceRoute) {
        navigate {
            self.pane = .services
            self.serviceRoute = route
        }
    }

    /// 保存新配置后，把路由换成已保存的配置，不经过拦截。
    func replaceServiceRoute(_ route: ServiceRoute) {
        serviceRoute = route
    }

    func backToServices() {
        navigate { self.serviceRoute = nil }
    }

    /// 关闭设置窗口前调用。返回 `true` 表示可以直接关闭。
    func requestClose(_ close: @escaping () -> Void) -> Bool {
        guard hasUnsavedChanges() else { return true }
        pendingAction = PendingAction(perform: close)
        return false
    }

    private func navigate(_ action: @escaping () -> Void) {
        if hasUnsavedChanges() {
            pendingAction = PendingAction(perform: action)
        } else {
            action()
        }
    }

    // MARK: - 未保存修改的拦截

    func registerEditor(hasUnsavedChanges: @escaping () -> Bool, save: @escaping () -> Bool) -> UUID {
        let token = UUID()
        guardToken = token
        self.hasUnsavedChanges = hasUnsavedChanges
        saveChanges = save
        return token
    }

    func unregisterEditor(_ token: UUID) {
        guard guardToken == token else { return }
        guardToken = nil
        hasUnsavedChanges = { false }
        saveChanges = { true }
    }

    /// 处理提示的选择：`save == true` 保存后继续，`false` 放弃修改继续，`nil` 取消。
    func resolvePending(save: Bool?) {
        guard let action = pendingAction else { return }
        pendingAction = nil
        switch save {
        case true?:
            if saveChanges() { finish(action) }
        case false?:
            finish(action)
        case nil:
            break
        }
    }

    private func finish(_ action: PendingAction) {
        // 放弃或已保存后，离开的页面不再拦截
        if let guardToken { unregisterEditor(guardToken) }
        action.perform()
    }
}
