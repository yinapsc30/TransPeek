import AppKit
import TransPeekKit

/// 应用级的共享服务（组合根）。
@MainActor
final class AppServices {
    let settings: SettingsStore
    let profiles: TranslationProfileStore
    let secrets: any SecretStore
    let presets: LLMPresetCatalog
    let presetStore: PresetStore
    let registry: ProviderRegistry
    let translation: TranslationService
    let ocr: any OCREngine
    let ocrWarmUp: OCRWarmUp
    let permissions: PermissionManager
    let presenter: WindowPresenter

    /// - Parameter secrets: 默认使用钥匙串；Debug 截图工具传入内存实现，避免触发钥匙串授权弹窗。
    init(secrets: (any SecretStore)? = nil) {
        settings = SettingsStore()
        profiles = TranslationProfileStore()
        self.secrets = secrets ?? KeychainStore()
        presets = .bundled
        presetStore = PresetStore()
        registry = ProviderRegistry(profiles: profiles, settings: settings, secrets: self.secrets, presets: presets)
        translation = TranslationService(resolver: registry)
        // 全局最多 2 个并发 Vision 请求（design.md「并发模型」）
        ocr = ThrottledOCREngine(base: VisionOCREngine(), limit: 2)
        ocrWarmUp = OCRWarmUp()
        permissions = PermissionManager()
        presenter = WindowPresenter()
    }

    /// 启动后在后台预热 OCR：自动检测和默认源语言各一次（R14.5）。
    /// 每个新安装或新编译的版本第一次识别约需半分钟，预热后区域的第一次识别不用再等。
    func warmUpOCR() {
        let warmUp = ocrWarmUp
        let source = settings.settings.defaultSourceLanguage?.visionCode
        Task(priority: .utility) {
            await warmUp.warmUp(languages: nil)
            if let source { await warmUp.warmUp(languages: [source]) }
        }
    }
}
