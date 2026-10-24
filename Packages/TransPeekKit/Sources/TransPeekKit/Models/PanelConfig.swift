import CoreGraphics
import Foundation

/// 贴边方向。
public enum DockEdge: String, Codable, Sendable, CaseIterable {
    case top, bottom, left, right

    public var displayName: String {
        switch self {
        case .top: "上"
        case .bottom: "下"
        case .left: "左"
        case .right: "右"
        }
    }

    /// 是否为水平方向的边（上、下）。
    public var isHorizontal: Bool { self == .top || self == .bottom }
}

/// 面板摆放方式（R9、R10）。
public enum PanelPlacement: Codable, Sendable, Equatable {
    /// 贴合目标窗口某条边，`thickness` 为面板的宽（左右）或高（上下）。
    case docked(edge: DockEdge, thickness: Double)
    /// 悬浮，`offset` 为相对目标窗口左上角的偏移。
    case floating(offset: CGPoint, size: CGSize)

    public var isDocked: Bool {
        if case .docked = self { return true }
        return false
    }
}

/// 面板配置，按预设保存（R9.5、R10.2）。
public struct PanelConfig: Codable, Sendable, Equatable {
    public var placement: PanelPlacement
    /// 背景不透明度，0.2...1.0（R10.5）。
    public var opacity: Double
    public var fontSize: Double
    public var showsOriginal: Bool
    /// 仅贴边内侧模式使用（R9.3）。
    public var collapsed: Bool

    public static let opacityRange: ClosedRange<Double> = 0.2...1.0
    public static let fontSizeRange: ClosedRange<Double> = 10...32
    public static let defaultThickness: Double = 320

    public init(
        placement: PanelPlacement = .docked(edge: .right, thickness: PanelConfig.defaultThickness),
        opacity: Double = 0.85,
        fontSize: Double = 14,
        showsOriginal: Bool = true,
        collapsed: Bool = false
    ) {
        self.placement = placement
        self.opacity = min(max(opacity, Self.opacityRange.lowerBound), Self.opacityRange.upperBound)
        self.fontSize = min(max(fontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        self.showsOriginal = showsOriginal
        self.collapsed = collapsed
    }

    public static let `default` = PanelConfig()
}
