import CoreGraphics
import Foundation
import Testing
@testable import TransPeekKit

@Suite("PresetStore")
struct PresetStoreTests {
    private func samplePreset(_ name: String = "聊天", bundleID: String = "com.example.game") -> AppPreset {
        AppPreset(
            bundleID: bundleID,
            regions: [Region(name: name, rect: CGRect(x: 0, y: 0.5, width: 0.4, height: 0.3), targetLanguage: .simplifiedChinese)],
            // ISO 8601 只保存到秒，测试使用整秒时间
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    @Test("读写往返")
    func roundTrip() async throws {
        let store = PresetStore(directory: try makeTemporaryDirectory())
        let preset = samplePreset()
        try await store.save(preset)
        let loaded = await store.load(bundleID: preset.bundleID)
        #expect(loaded.preset == preset)
        #expect(!loaded.recoveredFromCorruption)
    }

    @Test("文件不存在时返回空预设")
    func missingFile() async throws {
        let store = PresetStore(directory: try makeTemporaryDirectory())
        let loaded = await store.load(bundleID: "com.example.none")
        #expect(loaded.preset.regions.isEmpty)
        #expect(!loaded.recoveredFromCorruption)
    }

    @Test("损坏文件备份为 .corrupt 并返回空预设")
    func corruptFile() async throws {
        let directory = try makeTemporaryDirectory()
        let store = PresetStore(directory: directory)
        let url = await store.fileURL(for: "com.example.game")
        try Data("{not json".utf8).write(to: url)

        let loaded = await store.load(bundleID: "com.example.game")
        #expect(loaded.recoveredFromCorruption)
        #expect(loaded.preset.regions.isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Bundle ID 中的特殊字符不会造成路径穿越")
    func sanitizedFileName() async throws {
        let directory = try makeTemporaryDirectory()
        let store = PresetStore(directory: directory)
        let url = await store.fileURL(for: "../../etc/passwd")
        #expect(url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
    }

    @Test("防抖：短时间内多次修改只写一次，写入最后一次的内容")
    func debouncedSave() async throws {
        let store = PresetStore(directory: try makeTemporaryDirectory(), debounce: .milliseconds(80))
        for index in 1...5 {
            await store.scheduleSave(samplePreset("区域 \(index)"))
        }
        // 防抖期间读取到的是待写入的最新值
        #expect(await store.load(bundleID: "com.example.game").preset.regions.first?.name == "区域 5")
        #expect(await store.writeCount == 0)

        try await Task.sleep(for: .milliseconds(400))
        #expect(await store.writeCount == 1)

        let fresh = PresetStore(directory: await store.fileURL(for: "x").deletingLastPathComponent())
        #expect(await fresh.load(bundleID: "com.example.game").preset.regions.first?.name == "区域 5")
    }

    @Test("flush 立即写入待写入的预设")
    func flush() async throws {
        let store = PresetStore(directory: try makeTemporaryDirectory(), debounce: .seconds(60))
        await store.scheduleSave(samplePreset(bundleID: "a.b"))
        await store.scheduleSave(samplePreset(bundleID: "c.d"))
        await store.flush()
        #expect(await store.writeCount == 2)
    }
}

@Suite("SettingsStore")
struct SettingsStoreTests {
    private func makeDefaults() -> UserDefaults {
        let name = "TransPeekKitTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("默认值与需求一致")
    func defaults() {
        let settings = SettingsStore(defaults: makeDefaults()).settings
        #expect(settings.defaultSourceLanguage == nil)
        #expect(settings.sampleFPS == 4)
        #expect(settings.ocrConfidenceThreshold == 0.3)
        #expect(settings.historyLimit == 500)
        #expect(settings.debugLogging == false)
    }

    @Test("修改后持久化并发出通知，数值被限制在合法范围")
    func updatePersistsAndNotifies() async throws {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        let notifications = NotificationCounter(name: SettingsStore.didChangeNotification, object: store)

        store.update { $0.sampleFPS = 99; $0.defaultTargetLanguage = Language("ja") }
        #expect(store.settings.sampleFPS == 10)
        #expect(notifications.count == 1)

        store.update { $0.sampleFPS = 10 } // 没有变化，不通知
        #expect(notifications.count == 1)

        let reloaded = SettingsStore(defaults: defaults).settings
        #expect(reloaded.sampleFPS == 10)
        #expect(reloaded.defaultTargetLanguage == Language("ja"))
    }
}

@Suite("TranslationProfileStore")
struct TranslationProfileStoreTests {
    @Test("首次启动内置 Google 配置")
    func defaultGoogleProfile() throws {
        let store = TranslationProfileStore(fileURL: try makeTemporaryDirectory().appendingPathComponent("p.json"))
        #expect(store.profiles.count == 1)
        #expect(store.profiles.first?.isGoogle == true)
    }

    @Test("读写往返，解析顺序为指定 → 默认 → 第一个")
    func upsertAndResolve() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("p.json")
        let store = TranslationProfileStore(fileURL: url)
        let google = store.profiles[0]
        let llm = TranslationProfile(name: "本地", kind: .llm(LLMConfig(
            presetID: "ollama", protocolKind: .openAICompatible, baseURL: URL(string: "http://localhost:11434/v1")!, model: "qwen"
        )))
        try store.upsert(llm)

        let reloaded = TranslationProfileStore(fileURL: url)
        #expect(reloaded.profiles == [google, llm])
        #expect(reloaded.resolve(llm.id, defaultID: google.id) == llm)
        #expect(reloaded.resolve(nil, defaultID: llm.id) == llm)
        #expect(reloaded.resolve(UUID(), defaultID: nil) == google)
    }

    @Test("API Key 不会写入配置文件；删除配置时同时删除 Key")
    func secretsNotWritten() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("p.json")
        let store = TranslationProfileStore(fileURL: url)
        let secrets = InMemorySecretStore()
        let llm = TranslationProfile(name: "OpenAI", kind: .llm(LLMConfig(
            presetID: "openai", protocolKind: .openAICompatible, baseURL: URL(string: "https://api.openai.com/v1")!, model: "m"
        )))
        try secrets.setSecret("sk-test-secret-123", for: llm.secretAccount)
        try secrets.setSecret("google-secret-456", for: SecretAccount.google)
        try store.upsert(llm)

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(!contents.contains("sk-test-secret-123"))
        #expect(!contents.contains("google-secret-456"))

        try store.remove(id: llm.id, secrets: secrets)
        #expect(secrets.secret(for: llm.secretAccount) == nil)
        #expect(store.profile(id: llm.id) == nil)
        // Google 配置删除时不删除全局 Key
        try store.remove(id: store.profiles[0].id, secrets: secrets)
        #expect(secrets.secret(for: SecretAccount.google) == "google-secret-456")
    }
}

@Suite("KeychainStore", .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil, "CI 环境没有可用的登录钥匙串"))
struct KeychainStoreTests {
    @Test("读、写、更新、删除")
    func readWriteDelete() throws {
        let store = KeychainStore(service: "com.transpeek.tests.\(UUID().uuidString)")
        let account = "test-account"
        defer { try? store.setSecret(nil, for: account) }

        #expect(store.secret(for: account) == nil)
        try store.setSecret("first", for: account)
        #expect(store.secret(for: account) == "first")
        try store.setSecret("second", for: account)
        #expect(store.secret(for: account) == "second")
        try store.setSecret(nil, for: account)
        #expect(store.secret(for: account) == nil)
        try store.setSecret("", for: account) // 删除不存在的条目不报错
    }
}

/// 统计通知次数（同步投递）。
final class NotificationCounter: @unchecked Sendable {
    private(set) var count = 0
    private var token: NSObjectProtocol?

    init(name: Notification.Name, object: AnyObject?) {
        token = NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
            self?.count += 1
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
