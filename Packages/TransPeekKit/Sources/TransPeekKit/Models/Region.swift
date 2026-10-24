import CoreGraphics
import Foundation

/// 区域模式（R4.3）。
public enum RegionMode: String, Codable, Sendable, CaseIterable {
    /// 单次：框选后或手动触发时识别一次。
    case once
    /// 对话：持续监听，新文本替换当前显示。
    case dialog
    /// 聊天：持续监听，只追加新出现的行。
    case chat

    public var displayName: String {
        switch self {
        case .once: "单次"
        case .dialog: "对话"
        case .chat: "聊天"
        }
    }

    /// 是否需要持续截取。
    public var isContinuous: Bool { self != .once }
}

/// 目标窗口上的一个识别区域（R4）。
public struct Region: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    /// 归一化坐标，相对目标窗口，原点左上，取值 0...1（R4.4）。
    public var rect: CGRect
    public var mode: RegionMode
    /// `nil` 表示自动检测。
    public var sourceLanguage: Language?
    public var targetLanguage: Language
    /// 翻译前移除匹配的文本片段（R4.8）。
    public var ignorePatterns: [String]
    public var isPaused: Bool
    public var panel: PanelConfig
    /// `nil` 表示使用全局默认翻译配置（R16.7）。
    public var translationProfileID: UUID?
    /// 过滤界面噪声（ocr-cleanup C1.1）。
    public var filtersNoise: Bool
    /// LLM 智能整理（ocr-cleanup C2.1），只在翻译配置是 LLM 时生效。
    public var smartCleanup: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, rect, mode, sourceLanguage, targetLanguage, ignorePatterns, isPaused, panel
        case translationProfileID, filtersNoise, smartCleanup
    }

    /// 旧预设文件没有 `filtersNoise`、`smartCleanup`，按模式取默认值（C1.1）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        rect = try c.decode(CGRect.self, forKey: .rect)
        mode = try c.decode(RegionMode.self, forKey: .mode)
        sourceLanguage = try c.decodeIfPresent(Language.self, forKey: .sourceLanguage)
        targetLanguage = try c.decode(Language.self, forKey: .targetLanguage)
        ignorePatterns = try c.decodeIfPresent([String].self, forKey: .ignorePatterns) ?? []
        isPaused = try c.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        panel = try c.decodeIfPresent(PanelConfig.self, forKey: .panel) ?? .default
        translationProfileID = try c.decodeIfPresent(UUID.self, forKey: .translationProfileID)
        filtersNoise = try c.decodeIfPresent(Bool.self, forKey: .filtersNoise) ?? (mode == .chat)
        smartCleanup = try c.decodeIfPresent(Bool.self, forKey: .smartCleanup) ?? true
    }

    public init(
        id: UUID = UUID(),
        name: String,
        rect: CGRect,
        mode: RegionMode = .chat,
        sourceLanguage: Language? = nil,
        targetLanguage: Language,
        ignorePatterns: [String] = [],
        isPaused: Bool = false,
        panel: PanelConfig = .default,
        translationProfileID: UUID? = nil,
        filtersNoise: Bool? = nil,
        smartCleanup: Bool = true
    ) {
        self.filtersNoise = filtersNoise ?? (mode == .chat)
        self.smartCleanup = smartCleanup
        self.id = id
        self.name = name
        self.rect = rect.clampedToUnit
        self.mode = mode
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.ignorePatterns = ignorePatterns
        self.isPaused = isPaused
        self.panel = panel
        self.translationProfileID = translationProfileID
    }

    /// 把归一化区域换算为窗口内的像素/点坐标（原点左上）。
    public func absoluteRect(in size: CGSize) -> CGRect {
        CGRect(
            x: rect.minX * size.width,
            y: rect.minY * size.height,
            width: rect.width * size.width,
            height: rect.height * size.height
        ).integral
    }
}

extension CGRect {
    /// 限制在 0...1 的单位矩形内。
    public var clampedToUnit: CGRect {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let clipped = standardized.intersection(unit)
        return clipped.isNull ? .zero : clipped
    }

    /// 把绝对矩形换算为相对 `container` 的归一化矩形（两者使用同一坐标系）。
    public func normalized(in container: CGRect) -> CGRect {
        guard container.width > 0, container.height > 0 else { return .zero }
        return CGRect(
            x: (minX - container.minX) / container.width,
            y: (minY - container.minY) / container.height,
            width: width / container.width,
            height: height / container.height
        ).clampedToUnit
    }
}
