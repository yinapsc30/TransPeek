import Foundation
import Observation
import TransPeekKit

/// 设置页共享的依赖和模型。在应用生命周期内只创建一次，设置窗口重新打开时复用。
@MainActor
final class SettingsContext {
    struct Actions {
        let showPermissionGuide: () -> Void
        let showWindowPicker: () -> Void
        let showRegionManager: () -> Void
    }

    let services: AppServices
    let coordinator: SessionCoordinator
    let router = SettingsRouter()
    let settings: SettingsModel
    let profiles: ProfilesModel
    let statuses = ServiceStatusStore()
    let setup: SetupModel
    let launchAtLogin = LaunchAtLogin()
    let hotkeyConflicts: () -> [HotkeyAction]
    let actions: Actions

    init(services: AppServices, coordinator: SessionCoordinator, hotkeyConflicts: @escaping () -> [HotkeyAction], actions: Actions) {
        self.services = services
        self.coordinator = coordinator
        self.hotkeyConflicts = hotkeyConflicts
        self.actions = actions
        settings = SettingsModel(store: services.settings)
        profiles = ProfilesModel(store: services.profiles)
        setup = SetupModel(services: services, coordinator: coordinator)
    }

    var defaultProfileID: UUID? {
        services.profiles.resolve(nil, defaultID: settings.settings.defaultProfileID)?.id
    }

    func hasAPIKey(_ profile: TranslationProfile) -> Bool {
        services.secrets.secret(for: profile.secretAccount) != nil
    }

    func requiresAPIKey(_ profile: TranslationProfile) -> Bool {
        guard let config = profile.llmConfig else { return true }
        return services.presets.presetOrCustom(id: config.presetID)?.requiresAPIKey ?? false
    }

    func status(of profile: TranslationProfile) -> ServiceStatus {
        ServiceStatus.evaluate(
            profile, hasAPIKey: hasAPIKey(profile), requiresAPIKey: requiresAPIKey(profile),
            test: statuses.results[profile.id] ?? .idle
        )
    }

    /// 卡片上的摘要（S6.1）。
    func summary(of profile: TranslationProfile) -> String {
        guard let config = profile.llmConfig else { return "Cloud Translation v2" }
        var parts = [config.model.isEmpty ? "未填写模型" : config.model]
        if let host = config.baseURL.host, LLMConfigValidator.isLocal(host: host) {
            parts.append(host + (config.baseURL.port.map { ":\($0)" } ?? ""))
        }
        parts.append(config.contextCount == 0 ? "不带上下文" : "上下文 \(config.contextCount) 条")
        if config.fallbackToGoogle { parts.append("失败时回退到 Google") }
        return parts.joined(separator: " · ")
    }
}

/// 每个翻译配置的“测试连接”结果，只保存在内存中（S6.2）。
@MainActor
@Observable
final class ServiceStatusStore {
    private(set) var results: [UUID: ConnectionTestState] = [:]

    func run(_ profile: TranslationProfile, apiKey: String, services: AppServices) async {
        results[profile.id] = .running
        results[profile.id] = await runConnectionTest(profile: profile, apiKey: apiKey, services: services)
    }

    func clear(_ id: UUID) {
        results.removeValue(forKey: id)
    }
}

/// “开始使用”的状态（S2）。权限状态直接读取 `PermissionManager`，其余在相关数据变化时刷新。
@MainActor
@Observable
final class SetupModel {
    private(set) var serviceConfigured = false
    private(set) var hasRegion = false

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let coordinator: SessionCoordinator
    @ObservationIgnored private var observers: [NotificationToken] = []

    init(services: AppServices, coordinator: SessionCoordinator) {
        self.services = services
        self.coordinator = coordinator
        for (name, object) in [
            (TranslationProfileStore.didChangeNotification, services.profiles as AnyObject),
            (SettingsStore.didChangeNotification, services.settings as AnyObject),
        ] {
            observers.append(NotificationToken(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }))
        }
        refresh()
    }

    var progress: SetupProgress {
        SetupProgress(
            permissionGranted: services.permissions.screenCaptureGranted,
            serviceConfigured: serviceConfigured,
            hasRegion: hasRegion || !coordinator.regions.isEmpty
        )
    }

    func refresh() {
        if let profile = services.profiles.resolve(nil, defaultID: services.settings.settings.defaultProfileID) {
            let hasKey = services.secrets.secret(for: profile.secretAccount) != nil
            let requiresKey = profile.llmConfig.map { services.presets.presetOrCustom(id: $0.presetID)?.requiresAPIKey ?? false } ?? true
            serviceConfigured = ServiceStatus.isConfigured(profile, hasAPIKey: hasKey, requiresAPIKey: requiresKey)
        } else {
            serviceConfigured = false
        }
        let store = services.presetStore
        Task { [weak self] in
            let any = await store.hasAnyRegion()
            self?.hasRegion = any
        }
    }
}

/// 用示例文本发起真实请求，不经过缓存（R13.3、R16.11、S7.5）。
@MainActor
func runConnectionTest(profile: TranslationProfile, apiKey: String, services: AppServices) async -> ConnectionTestState {
    let secrets = InMemorySecretStore()
    try? secrets.setSecret(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: profile.secretAccount)
    if !profile.isGoogle {
        try? secrets.setSecret(services.secrets.secret(for: SecretAccount.google), for: SecretAccount.google)
    }
    let resolved = ProviderRegistry.makeResolved(profile, secrets: secrets, presets: services.presets)
    let request = TranslationRequest(
        texts: [ConnectionTest.sampleText],
        source: .english,
        target: services.settings.settings.defaultTargetLanguage,
        appName: "TransPeek"
    )
    let start = ContinuousClock.now
    do {
        let results = try await resolved.provider.translate(request)
        let milliseconds = Int(((ContinuousClock.now - start).seconds * 1000).rounded())
        switch results.first {
        case let .success(output)?: return .success(translation: output.text ?? "（未返回译文）", milliseconds: milliseconds)
        case let .failure(error)?: return .failure(error.localizedDescription)
        case nil: return .failure("没有返回结果")
        }
    } catch {
        return .failure(error.localizedDescription)
    }
}

enum ConnectionTest {
    static let sampleText = "S> Choco Candy Cookie 180K"
}
