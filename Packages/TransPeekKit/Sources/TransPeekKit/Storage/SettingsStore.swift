import Foundation
import os

/// 通用设置（R13.1）。
public struct AppSettings: Codable, Sendable, Equatable {
    public static let sampleFPSRange: ClosedRange<Int> = 1...10
    public static let confidenceRange: ClosedRange<Double> = 0...1
    public static let historyLimitRange: ClosedRange<Int> = 50...5000

    /// `nil` 表示自动检测。
    public var defaultSourceLanguage: Language?
    public var defaultTargetLanguage: Language
    /// `nil` 时使用第一个翻译配置。
    public var defaultProfileID: UUID?
    public var sampleFPS: Int
    public var ocrConfidenceThreshold: Double
    public var historyLimit: Int
    public var panelFontSize: Double
    public var panelOpacity: Double
    /// 调试日志：开启后日志中会输出识别文本（不包含 API Key，R15.3）。
    public var debugLogging: Bool
    /// 新面板的默认位置（S5.2）。
    public var defaultPanelPlacement: DefaultPanelPlacement
    /// 新面板默认是否显示原文（S5.2）。
    public var defaultShowsOriginal: Bool

    public init(
        defaultSourceLanguage: Language? = nil,
        defaultTargetLanguage: Language = .systemDefault(),
        defaultProfileID: UUID? = nil,
        sampleFPS: Int = 4,
        ocrConfidenceThreshold: Double = 0.3,
        historyLimit: Int = 500,
        panelFontSize: Double = 14,
        panelOpacity: Double = 0.85,
        debugLogging: Bool = false,
        defaultPanelPlacement: DefaultPanelPlacement = .right,
        defaultShowsOriginal: Bool = true
    ) {
        self.defaultSourceLanguage = defaultSourceLanguage
        self.defaultTargetLanguage = defaultTargetLanguage
        self.defaultProfileID = defaultProfileID
        self.sampleFPS = sampleFPS
        self.ocrConfidenceThreshold = ocrConfidenceThreshold
        self.historyLimit = historyLimit
        self.panelFontSize = panelFontSize
        self.panelOpacity = panelOpacity
        self.debugLogging = debugLogging
        self.defaultPanelPlacement = defaultPanelPlacement
        self.defaultShowsOriginal = defaultShowsOriginal
    }

    private enum CodingKeys: String, CodingKey {
        case defaultSourceLanguage, defaultTargetLanguage, defaultProfileID, sampleFPS, ocrConfidenceThreshold
        case historyLimit, panelFontSize, panelOpacity, debugLogging, defaultPanelPlacement, defaultShowsOriginal
    }

    /// 缺少的字段取默认值，兼容旧版本保存的设置。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        defaultSourceLanguage = try c.decodeIfPresent(Language.self, forKey: .defaultSourceLanguage)
        defaultTargetLanguage = try c.decodeIfPresent(Language.self, forKey: .defaultTargetLanguage) ?? defaults.defaultTargetLanguage
        defaultProfileID = try c.decodeIfPresent(UUID.self, forKey: .defaultProfileID)
        sampleFPS = try c.decodeIfPresent(Int.self, forKey: .sampleFPS) ?? defaults.sampleFPS
        ocrConfidenceThreshold = try c.decodeIfPresent(Double.self, forKey: .ocrConfidenceThreshold) ?? defaults.ocrConfidenceThreshold
        historyLimit = try c.decodeIfPresent(Int.self, forKey: .historyLimit) ?? defaults.historyLimit
        panelFontSize = try c.decodeIfPresent(Double.self, forKey: .panelFontSize) ?? defaults.panelFontSize
        panelOpacity = try c.decodeIfPresent(Double.self, forKey: .panelOpacity) ?? defaults.panelOpacity
        debugLogging = try c.decodeIfPresent(Bool.self, forKey: .debugLogging) ?? defaults.debugLogging
        defaultPanelPlacement = (try? c.decodeIfPresent(DefaultPanelPlacement.self, forKey: .defaultPanelPlacement)) ?? defaults.defaultPanelPlacement
        defaultShowsOriginal = try c.decodeIfPresent(Bool.self, forKey: .defaultShowsOriginal) ?? defaults.defaultShowsOriginal
    }

    /// 新区域的面板配置（S5.2、S5.3）。
    public var newPanelConfig: PanelConfig {
        PanelConfig(
            placement: defaultPanelPlacement.placement,
            opacity: panelOpacity,
            fontSize: panelFontSize,
            showsOriginal: defaultShowsOriginal
        )
    }

    /// 把所有数值限制在合法范围内。
    public func clamped() -> AppSettings {
        var copy = self
        copy.sampleFPS = Self.clamp(sampleFPS, Self.sampleFPSRange)
        copy.ocrConfidenceThreshold = Self.clamp(ocrConfidenceThreshold, Self.confidenceRange)
        copy.historyLimit = Self.clamp(historyLimit, Self.historyLimitRange)
        copy.panelFontSize = Self.clamp(panelFontSize, PanelConfig.fontSizeRange)
        copy.panelOpacity = Self.clamp(panelOpacity, PanelConfig.opacityRange)
        return copy
    }

    private static func clamp<T: Comparable>(_ value: T, _ range: ClosedRange<T>) -> T {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// 新面板的默认位置（S5.2）。
public enum DefaultPanelPlacement: String, Codable, Sendable, CaseIterable {
    case right, left, bottom, floating

    public var displayName: String {
        switch self {
        case .right: "右侧"
        case .left: "左侧"
        case .bottom: "底部"
        case .floating: "悬浮"
        }
    }

    /// 悬浮时放在窗口右上角内侧（偏移在面板第一次显示时按窗口大小修正）。
    public var placement: PanelPlacement {
        switch self {
        case .right: .docked(edge: .right, thickness: PanelConfig.defaultThickness)
        case .left: .docked(edge: .left, thickness: PanelConfig.defaultThickness)
        case .bottom: .docked(edge: .bottom, thickness: 160)
        case .floating: .floating(offset: CGPoint(x: 24, y: 48), size: CGSize(width: 320, height: 360))
        }
    }
}

/// 设置的读写与变更通知，保存在 UserDefaults（design.md「持久化」）。修改后立即生效（R13.2）。
public final class SettingsStore: Sendable {
    /// 设置变更时发出，`object` 为 `SettingsStore`。
    public static let didChangeNotification = Notification.Name("TransPeekSettingsDidChange")

    private static let key = "settings.v1"
    private nonisolated(unsafe) let defaults: UserDefaults
    private let cache: OSAllocatedUnfairLock<AppSettings>

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loaded: AppSettings
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            loaded = decoded.clamped()
        } else {
            loaded = AppSettings()
        }
        cache = OSAllocatedUnfairLock(initialState: loaded)
    }

    public var settings: AppSettings {
        cache.withLock { $0 }
    }

    public func update(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        let newValue = copy.clamped()
        let changed = cache.withLock { current -> Bool in
            guard current != newValue else { return false }
            current = newValue
            return true
        }
        guard changed else { return }
        if let data = try? JSONEncoder().encode(newValue) {
            defaults.set(data, forKey: Self.key)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
