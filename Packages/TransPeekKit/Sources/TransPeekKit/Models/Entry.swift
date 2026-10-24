import Foundation

/// 条目的翻译状态。
public enum TranslationState: Sendable, Equatable {
    case pending
    /// `fallback` 表示由 Google 回退翻译（R16.12）。
    case done(String, fallback: Bool = false)
    /// 最终失败，用户可手动重试（R8.6）。
    case failed(String)
    /// 没有可用的翻译服务（如未配置 API Key），只显示原文（R8.3）。
    case unavailable(String)
    /// 名字/时间行：显示原文灰色小字，不翻译（ocr-cleanup C3.1）。
    case metadata
    /// 界面文字：从面板中移除（ocr-cleanup C2.3）。
    case hidden

    public var translatedText: String? {
        if case let .done(text, _) = self { return text }
        return nil
    }

    public var isFinal: Bool { self != .pending }
}

/// 面板中的一条记录。只保存在内存中（R15.2）。
public struct Entry: Sendable, Identifiable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// 聊天或单次模式的一行。
        case line
        /// “可能有遗漏”标记（R7.4）。
        case gapMarker
        /// 对话模式的一段文本。
        case dialogSnapshot
    }

    public let id: UUID
    public let regionID: UUID
    public let timestamp: Date
    public let original: String
    public var translation: TranslationState
    public let kind: Kind

    public init(
        id: UUID = UUID(),
        regionID: UUID,
        timestamp: Date = Date(),
        original: String,
        translation: TranslationState = .pending,
        kind: Kind = .line
    ) {
        self.id = id
        self.regionID = regionID
        self.timestamp = timestamp
        self.original = original
        self.translation = translation
        self.kind = kind
    }

    public static func gapMarker(regionID: UUID, timestamp: Date = Date()) -> Entry {
        Entry(regionID: regionID, timestamp: timestamp, original: "", translation: .done(""), kind: .gapMarker)
    }
}
