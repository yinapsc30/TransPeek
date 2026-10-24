import Foundation

/// 根据翻译配置创建 provider，并按配置 ID 缓存；配置或设置变化时自动失效（design.md「TranslationService」）。
public actor ProviderRegistry: ProviderResolving {
    private let profiles: TranslationProfileStore
    private let settings: SettingsStore
    private let secrets: any SecretStore
    private let presets: LLMPresetCatalog
    private let transport: any HTTPTransport
    private var cache: [UUID: ResolvedProvider] = [:]
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    public init(
        profiles: TranslationProfileStore,
        settings: SettingsStore,
        secrets: any SecretStore,
        presets: LLMPresetCatalog = .bundled,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.profiles = profiles
        self.settings = settings
        self.secrets = secrets
        self.presets = presets
        self.transport = transport

        let center = NotificationCenter.default
        for (name, object) in [
            (TranslationProfileStore.didChangeNotification, profiles as AnyObject),
            (SettingsStore.didChangeNotification, settings as AnyObject),
        ] {
            observers.append(center.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
                Task { await self?.invalidate() }
            })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// API Key 修改后由设置界面调用（钥匙串没有变更通知）。
    public func invalidate() {
        cache.removeAll()
    }

    public func resolve(_ profileID: UUID?) async -> ResolvedProvider? {
        guard let profile = profiles.resolve(profileID, defaultID: settings.settings.defaultProfileID) else { return nil }
        if let cached = cache[profile.id] { return cached }
        let resolved = Self.makeResolved(profile, secrets: secrets, presets: presets, transport: transport)
        cache[profile.id] = resolved
        return resolved
    }

    /// 根据配置创建 provider，也用于设置页的“测试连接”（不经过缓存，R16.11）。
    public static func makeResolved(
        _ profile: TranslationProfile,
        secrets: any SecretStore,
        presets: LLMPresetCatalog = .bundled,
        transport: any HTTPTransport = URLSessionTransport()
    ) -> ResolvedProvider {
        let googleKey = secrets.secret(for: SecretAccount.google)
        switch profile.kind {
        case .google:
            return ResolvedProvider(
                profileID: profile.id,
                provider: GoogleTranslateProvider(apiKey: googleKey, transport: transport),
                policy: .google
            )
        case let .llm(config):
            let preset = presets.presetOrCustom(id: config.presetID)
            let key = secrets.secret(for: profile.secretAccount)
            let missingKey = (preset?.requiresAPIKey ?? false) && (key ?? "").isEmpty
            let client: any LLMClient = switch config.protocolKind {
            case .openAICompatible: OpenAICompatibleClient(config: config, apiKey: key, transport: transport)
            case .anthropic: AnthropicClient(config: config, apiKey: key, transport: transport)
            }
            let provider = LLMTranslationProvider(
                config: config,
                client: client,
                jsonMode: preset?.supportsJSONMode ?? false,
                missingKeyReason: missingKey ? "“\(profile.name)”未填写 API Key，请在设置中填写" : nil
            )
            let fallback: (any TranslationProvider)? = if config.fallbackToGoogle, let googleKey, !googleKey.isEmpty {
                GoogleTranslateProvider(apiKey: googleKey, transport: transport)
            } else {
                nil
            }
            return ResolvedProvider(profileID: profile.id, provider: provider, fallback: fallback, policy: .llm)
        }
    }
}
