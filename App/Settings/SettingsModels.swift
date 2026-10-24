import Foundation
import Observation
import ServiceManagement
import TransPeekKit

/// 通知观察者的令牌，释放时自动移除观察。
final class NotificationToken: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}

/// SettingsStore 的可观察包装，修改后立即写回并生效（R13.2）。
@MainActor
@Observable
final class SettingsModel {
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            store.update { $0 = settings }
        }
    }

    @ObservationIgnored let store: SettingsStore
    @ObservationIgnored private var observer: NotificationToken?

    init(store: SettingsStore) {
        self.store = store
        settings = store.settings
        observer = NotificationToken(NotificationCenter.default.addObserver(
            forName: SettingsStore.didChangeNotification, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.settings != store.settings else { return }
                self.settings = store.settings
            }
        })
    }
}

/// 翻译配置列表的可观察包装。
@MainActor
@Observable
final class ProfilesModel {
    private(set) var profiles: [TranslationProfile]
    @ObservationIgnored let store: TranslationProfileStore
    @ObservationIgnored private var observer: NotificationToken?

    init(store: TranslationProfileStore) {
        self.store = store
        profiles = store.profiles
        observer = NotificationToken(NotificationCenter.default.addObserver(
            forName: TranslationProfileStore.didChangeNotification, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.profiles = store.profiles }
        })
    }
}

/// 开机启动（R13.1），基于 SMAppService。
@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var isEnabled = SMAppService.mainApp.status == .enabled
    private(set) var errorMessage: String?

    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = "设置失败：\(error.localizedDescription)。建议把 TransPeek.app 放到“应用程序”文件夹后再试。"
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
