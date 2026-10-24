import CoreGraphics
import Foundation
import Testing
@testable import TransPeekKit

@Suite("数据模型编码")
struct ModelCodingTests {
    @Test("Language 编码为单个字符串")
    func languageEncodesAsString() throws {
        let data = try JSONEncoder().encode([Language("zh-CN")])
        #expect(String(decoding: data, as: UTF8.self) == #"["zh-CN"]"#)
        #expect(try roundTrip(Language("ja")) == Language("ja"))
        #expect(Language("ja").visionCode == "ja-JP")
        #expect(Language("xx").displayName == "xx")
    }

    @Test("系统语言映射", arguments: [
        (["zh-Hans-CN"], "zh-CN"),
        (["zh-Hant-TW"], "zh-TW"),
        (["ja-JP", "en-US"], "ja"),
        (["en-GB"], "en"),
        (["xx-YY"], "zh-CN"),
    ])
    func systemDefaultLanguage(preferred: [String], expected: String) {
        #expect(Language.systemDefault(preferred: preferred).code == expected)
    }

    @Test("Region 往返编码，并限制在单位矩形内")
    func regionRoundTrip() throws {
        let region = Region(
            name: "聊天",
            rect: CGRect(x: 0.1, y: 0.6, width: 0.5, height: 0.6), // 超出底边
            mode: .chat,
            sourceLanguage: .english,
            targetLanguage: .simplifiedChinese,
            ignorePatterns: [#"\bCH[O0]\w{1,2}\b"#],
            panel: PanelConfig(placement: .floating(offset: CGPoint(x: 10, y: 20), size: CGSize(width: 300, height: 200))),
            translationProfileID: UUID()
        )
        #expect(abs(region.rect.maxY - 1.0) < 1e-9)
        #expect(try roundTrip(region) == region)
    }

    @Test("区域换算为绝对坐标")
    func absoluteRect() {
        let region = Region(name: "r", rect: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25), targetLanguage: .english)
        #expect(region.absoluteRect(in: CGSize(width: 800, height: 400)) == CGRect(x: 200, y: 200, width: 400, height: 100))
        let normalized = CGRect(x: 300, y: 250, width: 400, height: 100)
            .normalized(in: CGRect(x: 100, y: 50, width: 800, height: 400))
        #expect(normalized == region.rect)
    }

    @Test("PanelPlacement 两种形态往返编码")
    func panelPlacementRoundTrip() throws {
        let docked = PanelConfig(placement: .docked(edge: .bottom, thickness: 120), opacity: 0.05, fontSize: 99)
        #expect(docked.opacity == PanelConfig.opacityRange.lowerBound)
        #expect(docked.fontSize == PanelConfig.fontSizeRange.upperBound)
        #expect(try roundTrip(docked) == docked)
        let floating = PanelConfig(placement: .floating(offset: CGPoint(x: -5, y: 8), size: CGSize(width: 320, height: 90)))
        #expect(try roundTrip(floating) == floating)
    }

    @Test("AppPreset 带 schemaVersion")
    func presetRoundTrip() throws {
        let preset = AppPreset(
            bundleID: "com.example.game",
            regions: [Region(name: "对话", rect: CGRect(x: 0, y: 0.7, width: 1, height: 0.3), mode: .dialog, targetLanguage: .simplifiedChinese)],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let data = try JSONCoding.encoder().encode(preset)
        #expect(String(decoding: data, as: UTF8.self).contains("\"schemaVersion\" : 2"))
        #expect(preset.panelGroups.count == 1)
        #expect(preset.currentGroupID == preset.panelGroups.first?.id)
        #expect(try roundTrip(preset) == preset)
    }

    @Test("TranslationProfile 两种类型往返编码")
    func profileRoundTrip() throws {
        let google = TranslationProfile.defaultGoogle()
        #expect(try roundTrip(google) == google)
        #expect(google.secretAccount == SecretAccount.google)

        let llm = TranslationProfile(name: "DeepSeek", kind: .llm(LLMConfig(
            presetID: "deepseek",
            protocolKind: .openAICompatible,
            baseURL: URL(string: "https://api.deepseek.com")!,
            model: "deepseek-flash",
            contextCount: 99,
            extraBody: #"{"thinking":{"type":"disabled"}}"#,
            fallbackToGoogle: true
        )))
        #expect(llm.llmConfig?.contextCount == LLMConfig.contextCountRange.upperBound)
        #expect(try roundTrip(llm) == llm)
        #expect(llm.secretAccount == "llm-\(llm.id.uuidString)")
    }

    @Test("LLMConfig 空提示词使用内置模板")
    func effectiveSystemPrompt() {
        var config = LLMConfig(presetID: "openai", protocolKind: .openAICompatible, baseURL: URL(string: "https://api.openai.com/v1")!, model: "m")
        #expect(config.effectiveSystemPrompt == PromptBuilder.defaultSystemPrompt)
        config.systemPrompt = "   \n"
        #expect(config.effectiveSystemPrompt == PromptBuilder.defaultSystemPrompt)
        config.systemPrompt = "custom {target_lang}"
        #expect(config.effectiveSystemPrompt == "custom {target_lang}")
    }
}
