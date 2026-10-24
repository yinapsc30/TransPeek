import Foundation

/// 面板外观样式，由摆放方式决定（panel-redesign P1.1）。
public enum PanelStyle: Sendable, Equatable {
    /// 贴边（外侧或内侧）：毛玻璃背景，信息完整。
    case hud
    /// 悬浮：几乎透明，文字带描边阴影。
    case subtitle

    public init(placement: PanelPlacement) {
        self = placement.isDocked ? .hud : .subtitle
    }

    /// 背景底色的不透明度（P1.3、P2.1、P3.5）。
    /// - Parameters:
    ///   - opacity: 用户设置的背景不透明度（0.2...1.0）。
    ///   - inside: 内侧贴边，沿用 R9.3 的更透明背景。
    ///   - hovering: 鼠标悬停在面板上。字幕样式悬停时加深背景，便于看清面板范围。
    public func backgroundOpacity(_ opacity: Double, inside: Bool, hovering: Bool) -> Double {
        let opacity = min(max(opacity, PanelConfig.opacityRange.lowerBound), PanelConfig.opacityRange.upperBound)
        switch self {
        case .hud:
            return (inside ? min(opacity, 0.75) : opacity) * 0.8
        case .subtitle:
            return hovering ? min(0.85, opacity * 0.3 + 0.4) : opacity * 0.3
        }
    }
}
