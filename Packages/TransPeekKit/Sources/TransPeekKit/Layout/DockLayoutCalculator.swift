import CoreGraphics
import Foundation

/// 贴边面板的位置计算结果。
public struct DockLayout: Sendable, Equatable {
    public enum Placement: Sendable, Equatable {
        /// 放在窗口外侧，不遮挡（R9.2）。
        case outside
        /// 外侧空间不足，放在窗口内侧边缘，半透明（R9.3、R12.2）。
        case inside
    }

    public let frame: CGRect
    public let placement: Placement
    /// 实际贴合的边。所选边外侧放不下时可能换到对边（R9.2）。
    public let edge: DockEdge

    public init(frame: CGRect, placement: Placement, edge: DockEdge) {
        self.frame = frame
        self.placement = placement
        self.edge = edge
    }
}

/// 贴边布局计算（design.md「贴边布局计算」）。纯函数。
///
/// 所有矩形使用同一个原点在左上、y 向下的坐标系（CG 全局坐标），App 层负责与 Cocoa 坐标互转。
public enum DockLayoutCalculator {
    /// 折叠后的厚度。
    public static let collapsedThickness: CGFloat = 6
    /// 内侧模式下面板最多占窗口对应方向尺寸的比例。
    public static let maxInsideRatio: CGFloat = 0.6
    public static let minThickness: CGFloat = 60
    /// 外侧空间不足设定厚度时，缩小后的最小厚度，再小就不放外侧（R9.2）。
    public static let minOutsideThickness: CGFloat = 200

    /// 依次尝试：所选边外侧（设定厚度）→ 所选边外侧（缩小）→ 对边外侧 → 所选边内侧（R9.2、R9.3）。
    ///
    /// - Parameters:
    ///   - window: 目标窗口 frame。
    ///   - visibleFrame: 目标窗口所在屏幕的可用区域（去掉菜单栏和 Dock）。
    ///   - collapsed: 仅在内侧模式下生效。
    public static func layout(window: CGRect, edge: DockEdge, thickness: CGFloat, visibleFrame: CGRect, collapsed: Bool) -> DockLayout {
        let thickness = max(thickness, minThickness)
        for candidateEdge in [edge, edge.opposite] {
            if let frame = outsideFrame(window: window, edge: candidateEdge, thickness: thickness, visibleFrame: visibleFrame) {
                return DockLayout(frame: frame, placement: .outside, edge: candidateEdge)
            }
        }
        let limit = (edge.isHorizontal ? window.height : window.width) * maxInsideRatio
        let insideThickness = collapsed ? collapsedThickness : min(thickness, max(limit, collapsedThickness))
        return DockLayout(frame: insideFrame(window: window, edge: edge, thickness: insideThickness), placement: .inside, edge: edge)
    }

    /// 外侧的面板位置。放不下设定厚度时缩小到可用空间（不小于 `minOutsideThickness`），否则返回 `nil`。
    /// 面板长度等于窗口边长，超出屏幕可用区域的部分裁掉（例如窗口上沿被菜单栏挡住一部分）。
    static func outsideFrame(window: CGRect, edge: DockEdge, thickness: CGFloat, visibleFrame: CGRect) -> CGRect? {
        let available: CGFloat = switch edge {
        case .right: visibleFrame.maxX - window.maxX
        case .left: window.minX - visibleFrame.minX
        case .top: window.minY - visibleFrame.minY
        case .bottom: visibleFrame.maxY - window.maxY
        }
        let fitted = min(thickness, floor(available + 0.5))
        guard fitted >= min(thickness, minOutsideThickness) else { return nil }

        var frame = outsideFrame(window: window, edge: edge, thickness: fitted)
        if edge.isHorizontal {
            let minX = max(frame.minX, visibleFrame.minX), maxX = min(frame.maxX, visibleFrame.maxX)
            guard maxX - minX >= minOutsideThickness else { return nil }
            frame.origin.x = minX
            frame.size.width = maxX - minX
        } else {
            let minY = max(frame.minY, visibleFrame.minY), maxY = min(frame.maxY, visibleFrame.maxY)
            guard maxY - minY >= minOutsideThickness else { return nil }
            frame.origin.y = minY
            frame.size.height = maxY - minY
        }
        return frame
    }

    static func outsideFrame(window: CGRect, edge: DockEdge, thickness: CGFloat) -> CGRect {
        switch edge {
        case .right: CGRect(x: window.maxX, y: window.minY, width: thickness, height: window.height)
        case .left: CGRect(x: window.minX - thickness, y: window.minY, width: thickness, height: window.height)
        case .top: CGRect(x: window.minX, y: window.minY - thickness, width: window.width, height: thickness)
        case .bottom: CGRect(x: window.minX, y: window.maxY, width: window.width, height: thickness)
        }
    }

    static func insideFrame(window: CGRect, edge: DockEdge, thickness: CGFloat) -> CGRect {
        switch edge {
        case .right: CGRect(x: window.maxX - thickness, y: window.minY, width: thickness, height: window.height)
        case .left: CGRect(x: window.minX, y: window.minY, width: thickness, height: window.height)
        case .top: CGRect(x: window.minX, y: window.minY, width: window.width, height: thickness)
        case .bottom: CGRect(x: window.minX, y: window.maxY - thickness, width: window.width, height: thickness)
        }
    }
}

extension DockEdge {
    public var opposite: DockEdge {
        switch self {
        case .left: .right
        case .right: .left
        case .top: .bottom
        case .bottom: .top
        }
    }
}

/// 悬浮面板拖动时的吸附判断（R10.3、R10.4）。
public enum SnapDetector {
    public static let defaultThreshold: CGFloat = 20

    /// 拖动中的面板靠近目标窗口某条边（外侧贴合或内侧贴合）时返回该边；同时靠近多条边时取最近的。
    public static func candidate(panel: CGRect, window: CGRect, threshold: CGFloat = defaultThreshold) -> DockEdge? {
        let verticalOverlap = min(panel.maxY, window.maxY) - max(panel.minY, window.minY)
        let horizontalOverlap = min(panel.maxX, window.maxX) - max(panel.minX, window.minX)

        var best: (edge: DockEdge, distance: CGFloat)?
        func consider(_ edge: DockEdge, _ distances: CGFloat..., overlap: CGFloat) {
            guard overlap > 0, let distance = distances.map(abs).min(), distance < threshold else { return }
            if best == nil || distance < best!.distance { best = (edge, distance) }
        }
        // 外侧贴合：面板的左边靠近窗口右边；内侧贴合：面板右边靠近窗口右边
        consider(.right, panel.minX - window.maxX, panel.maxX - window.maxX, overlap: verticalOverlap)
        consider(.left, panel.maxX - window.minX, panel.minX - window.minX, overlap: verticalOverlap)
        consider(.top, panel.maxY - window.minY, panel.minY - window.minY, overlap: horizontalOverlap)
        consider(.bottom, panel.minY - window.maxY, panel.maxY - window.maxY, overlap: horizontalOverlap)
        return best?.edge
    }

    /// 贴边面板被拖动后偏离原位置超过阈值时，切换为悬浮模式。
    public static func isDetached(panel: CGRect, dockedFrame: CGRect, threshold: CGFloat = defaultThreshold) -> Bool {
        max(abs(panel.minX - dockedFrame.minX), abs(panel.minY - dockedFrame.minY)) > threshold
    }
}

/// 面板上可拖动调整大小的区域（R9.1、R10.1）。纯函数，便于测试。
public enum PanelResizeZones {
    /// 边缘可拖动的宽度。
    public static let edgeWidth: CGFloat = 6
    /// 角的可拖动范围。
    public static let cornerSize: CGFloat = 14

    /// - Parameters:
    ///   - point: 面板内的点，原点左上。
    ///   - allowedEdges: 可以拖动的边。悬浮模式为四条边，贴边模式只有调整厚度的一条边。
    ///   - allowsCorners: 是否允许拖动角（悬浮模式）。
    /// - Returns: 被拖动的边的集合，角返回两条边。
    public static func edges(at point: CGPoint, in size: CGSize, allowedEdges: Set<DockEdge>, allowsCorners: Bool) -> Set<DockEdge>? {
        guard point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height else { return nil }
        let nearLeft = point.x <= edgeWidth, nearRight = point.x >= size.width - edgeWidth
        let nearTop = point.y <= edgeWidth, nearBottom = point.y >= size.height - edgeWidth

        // 只用下方两个角：上方两个角和标题栏的按钮重叠
        if allowsCorners, point.y >= size.height - cornerSize {
            let horizontal: DockEdge? = point.x <= cornerSize ? .left : (point.x >= size.width - cornerSize ? .right : nil)
            if let horizontal, allowedEdges.contains(horizontal), allowedEdges.contains(.bottom) {
                return [horizontal, .bottom]
            }
        }
        for (edge, near) in [(DockEdge.left, nearLeft), (.right, nearRight), (.top, nearTop), (.bottom, nearBottom)]
        where near && allowedEdges.contains(edge) {
            return [edge]
        }
        return nil
    }
}
