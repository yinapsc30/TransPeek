import Foundation

/// 语言，以 BCP-47 风格的代码表示（与 Google 翻译的语言代码一致，如 `en`、`zh-CN`、`ja`）。
/// 编码为单个字符串。`nil` 的 `Language?` 表示“自动检测”。
public struct Language: Hashable, Sendable, Codable, Identifiable, CustomStringConvertible {
    public let code: String

    public init(_ code: String) {
        self.code = code
    }

    public var id: String { code }
    public var description: String { code }

    public init(from decoder: Decoder) throws {
        code = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }

    private var info: LanguageInfo? { Language.catalog.first { $0.code == code } }

    /// 界面显示名（中文）。
    public var displayName: String { info?.displayName ?? code }

    /// 用于 LLM 提示词的英文名。
    public var englishName: String { info?.englishName ?? code }

    /// Vision 识别语言代码。
    public var visionCode: String { info?.visionCode ?? code }
}

struct LanguageInfo: Sendable {
    let code: String
    let displayName: String
    let englishName: String
    let visionCode: String
}

extension Language {
    public static let english = Language("en")
    public static let simplifiedChinese = Language("zh-CN")

    static let catalog: [LanguageInfo] = [
        LanguageInfo(code: "zh-CN", displayName: "简体中文", englishName: "Simplified Chinese", visionCode: "zh-Hans"),
        LanguageInfo(code: "zh-TW", displayName: "繁體中文", englishName: "Traditional Chinese", visionCode: "zh-Hant"),
        LanguageInfo(code: "en", displayName: "英语", englishName: "English", visionCode: "en-US"),
        LanguageInfo(code: "ja", displayName: "日语", englishName: "Japanese", visionCode: "ja-JP"),
        LanguageInfo(code: "ko", displayName: "韩语", englishName: "Korean", visionCode: "ko-KR"),
        LanguageInfo(code: "fr", displayName: "法语", englishName: "French", visionCode: "fr-FR"),
        LanguageInfo(code: "de", displayName: "德语", englishName: "German", visionCode: "de-DE"),
        LanguageInfo(code: "es", displayName: "西班牙语", englishName: "Spanish", visionCode: "es-ES"),
        LanguageInfo(code: "pt", displayName: "葡萄牙语", englishName: "Portuguese", visionCode: "pt-BR"),
        LanguageInfo(code: "it", displayName: "意大利语", englishName: "Italian", visionCode: "it-IT"),
        LanguageInfo(code: "ru", displayName: "俄语", englishName: "Russian", visionCode: "ru-RU"),
        LanguageInfo(code: "uk", displayName: "乌克兰语", englishName: "Ukrainian", visionCode: "uk-UA"),
        LanguageInfo(code: "th", displayName: "泰语", englishName: "Thai", visionCode: "th-TH"),
        LanguageInfo(code: "vi", displayName: "越南语", englishName: "Vietnamese", visionCode: "vi-VT"),
    ]

    /// 设置界面中可选的语言。
    public static var all: [Language] { catalog.map { Language($0.code) } }

    /// 系统首选语言对应的目标语言，无法匹配时为简体中文。
    public static func systemDefault(preferred: [String] = Locale.preferredLanguages) -> Language {
        for identifier in preferred {
            let lower = identifier.lowercased()
            if lower.hasPrefix("zh") {
                // zh-Hant / zh-TW / zh-HK 视为繁体，其余视为简体
                if lower.contains("hant") || lower.contains("-tw") || lower.contains("-hk") || lower.contains("-mo") {
                    return Language("zh-TW")
                }
                return .simplifiedChinese
            }
            let base = String(lower.prefix { $0 != "-" && $0 != "_" })
            if let match = catalog.first(where: { $0.code == base }) {
                return Language(match.code)
            }
        }
        return .simplifiedChinese
    }
}
