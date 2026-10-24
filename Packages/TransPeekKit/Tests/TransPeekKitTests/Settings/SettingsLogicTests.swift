import CoreGraphics
import Foundation
import Testing
@testable import TransPeekKit

@Suite("设置页逻辑")
struct SettingsLogicTests {
    @Test("旧版本保存的设置缺少新字段时取默认值")
    func legacySettingsDecode() throws {
        let legacy = #"{"sampleFPS": 8, "historyLimit": 300, "defaultTargetLanguage": "ja"}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        #expect(settings.sampleFPS == 8 && settings.historyLimit == 300)
        #expect(settings.defaultTargetLanguage == Language("ja"))
        #expect(settings.defaultPanelPlacement == .right)
        #expect(settings.defaultShowsOriginal == true)
        #expect(settings.panelOpacity == 0.85)
    }

    @Test("新字段往返编码，新区域使用默认面板配置")
    func newFields() throws {
        let settings = AppSettings(panelFontSize: 16, panelOpacity: 0.6, defaultPanelPlacement: .bottom, defaultShowsOriginal: false)
        #expect(try roundTrip(settings) == settings)
        let panel = settings.newPanelConfig
        #expect(panel.placement == .docked(edge: .bottom, thickness: 160))
        #expect(panel.fontSize == 16 && panel.opacity == 0.6 && panel.showsOriginal == false)
    }

    private let llm = TranslationProfile(name: "DeepSeek", kind: .llm(LLMConfig(
        presetID: "deepseek", protocolKind: .openAICompatible, baseURL: URL(string: "https://api.deepseek.com")!, model: "deepseek-flash"
    )))

    @Test("服务状态的优先级")
    func serviceStatus() {
        let google = TranslationProfile.defaultGoogle()
        #expect(ServiceStatus.evaluate(google, hasAPIKey: false, requiresAPIKey: true, test: .success(translation: "x", milliseconds: 9)) == .missingKey)
        #expect(ServiceStatus.evaluate(google, hasAPIKey: true, requiresAPIKey: true, test: .idle) == .untested)

        var noModel = llm
        noModel.kind = .llm(LLMConfig(presetID: "ollama", protocolKind: .openAICompatible, baseURL: URL(string: "http://localhost:11434/v1")!, model: " "))
        #expect(ServiceStatus.evaluate(noModel, hasAPIKey: false, requiresAPIKey: false, test: .idle) == .missingModel)
        #expect(ServiceStatus.evaluate(llm, hasAPIKey: true, requiresAPIKey: true, test: .failure("401")) == .failed("401"))
        #expect(ServiceStatus.evaluate(llm, hasAPIKey: true, requiresAPIKey: true, test: .success(translation: "x", milliseconds: 640)) == .passed(milliseconds: 640))
        #expect(ServiceStatus.evaluate(llm, hasAPIKey: true, requiresAPIKey: true, test: .running) == .testing)
        #expect(ServiceStatus.isConfigured(llm, hasAPIKey: true, requiresAPIKey: true))
        #expect(!ServiceStatus.isConfigured(llm, hasAPIKey: false, requiresAPIKey: true))
    }

    @Test("开始使用的未完成步骤数")
    func setupProgress() {
        #expect(SetupProgress(permissionGranted: true, serviceConfigured: false, hasRegion: false).pendingCount == 2)
        #expect(SetupProgress(permissionGranted: true, serviceConfigured: true, hasRegion: true).pendingCount == 0)
    }

    @Test("编辑草稿：脏状态、还原、逐项校验")
    func draftDirtyAndValidation() throws {
        var draft = ProfileDraft(profile: llm, apiKey: "sk-1", isNew: false)
        #expect(!draft.isDirty && draft.issues.isEmpty && !draft.canSave)

        draft.model = "deepseek-v4-pro"
        #expect(draft.isDirty && draft.canSave)
        draft.revert()
        #expect(!draft.isDirty && draft.model == "deepseek-flash")

        draft.apiKey = "sk-2" // 只改 Key 也算修改
        #expect(draft.isDirty)

        draft.baseURL = "http://api.example.com"
        draft.model = ""
        draft.extraBody = "[1]"
        draft.name = " "
        #expect(Set(draft.issues.keys) == [.baseURL, .model, .extraBody, .name])
        #expect(!draft.canSave && draft.makeProfile() == nil)
    }

    @Test("编辑草稿：新配置始终可保存，保存后不再是脏状态")
    func draftNewAndSave() throws {
        let preset = try #require(LLMPresetCatalog.bundled.preset(id: "ollama"))
        var draft = ProfileDraft(profile: TranslationProfile(name: "Ollama", kind: .llm(LLMPresetCatalog.bundled.makeConfig(presetID: "openai")!)), apiKey: "", isNew: true)
        draft.applyPreset(preset)
        #expect(draft.baseURL == "http://localhost:11434/v1" && draft.presetID == "ollama")
        #expect(draft.isDirty && draft.issues.keys.contains(.model))
        draft.model = "qwen3:8b"
        let profile = try #require(draft.makeProfile())
        #expect(profile.llmConfig?.model == "qwen3:8b" && profile.llmConfig?.systemPrompt == nil)
        draft.markSaved()
        #expect(!draft.isDirty && !draft.isNew)
    }

    @Test("Google 草稿不校验 LLM 字段")
    func googleDraft() {
        let draft = ProfileDraft(profile: .defaultGoogle(), apiKey: "", isNew: true)
        #expect(draft.issues.isEmpty)
        #expect(draft.makeProfile()?.isGoogle == true)
    }

    @Test("PresetStore.hasAnyRegion")
    func hasAnyRegion() async throws {
        let store = PresetStore(directory: try makeTemporaryDirectory())
        #expect(await !store.hasAnyRegion())
        try await store.save(AppPreset(bundleID: "a.b"))
        #expect(await !store.hasAnyRegion())
        try await store.save(AppPreset(bundleID: "c.d", regions: [Region(name: "r", rect: CGRect(x: 0, y: 0, width: 1, height: 1), targetLanguage: .english)]))
        #expect(await store.hasAnyRegion())
    }
}
