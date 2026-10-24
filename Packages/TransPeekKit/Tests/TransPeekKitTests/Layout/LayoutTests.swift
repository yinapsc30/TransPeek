import CoreGraphics
import Testing
@testable import TransPeekKit

@Suite("DockLayoutCalculator")
struct DockLayoutCalculatorTests {
    /// 1440x900 屏幕，菜单栏 25pt（左上原点坐标）。
    let screen = CGRect(x: 0, y: 25, width: 1440, height: 875)
    let window = CGRect(x: 300, y: 100, width: 800, height: 600)

    @Test("四个方向都有空间时放在外侧，长度等于该边长度", arguments: [
        (DockEdge.right, CGRect(x: 1100, y: 100, width: 300, height: 600)),
        (DockEdge.left, CGRect(x: 0, y: 100, width: 300, height: 600)),
        (DockEdge.top, CGRect(x: 300, y: 25, width: 800, height: 75)),
        (DockEdge.bottom, CGRect(x: 300, y: 700, width: 800, height: 150)),
    ])
    func outside(edge: DockEdge, expected: CGRect) {
        let thickness = edge.isHorizontal ? expected.height : expected.width
        let layout = DockLayoutCalculator.layout(window: window, edge: edge, thickness: thickness, visibleFrame: screen, collapsed: false)
        #expect(layout == DockLayout(frame: expected, placement: .outside, edge: edge))
    }

    @Test("贴近屏幕右边缘时换到左侧外侧")
    func oppositeWhenNoRoom() {
        let nearRight = CGRect(x: 800, y: 100, width: 600, height: 600)
        let layout = DockLayoutCalculator.layout(window: nearRight, edge: .right, thickness: 320, visibleFrame: screen, collapsed: false)
        #expect(layout == DockLayout(frame: CGRect(x: 480, y: 100, width: 320, height: 600), placement: .outside, edge: .left))
    }

    @Test("两侧外侧都放不下时切换为内侧")
    func insideWhenNoRoom() {
        let wide = CGRect(x: 100, y: 100, width: 1300, height: 600)
        let layout = DockLayoutCalculator.layout(window: wide, edge: .right, thickness: 320, visibleFrame: screen, collapsed: false)
        #expect(layout == DockLayout(frame: CGRect(x: 1080, y: 100, width: 320, height: 600), placement: .inside, edge: .right))
    }

    @Test("窗口铺满屏幕（全屏）时使用内侧，并支持折叠")
    func fullScreen() {
        let full = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let expanded = DockLayoutCalculator.layout(window: full, edge: .bottom, thickness: 160, visibleFrame: screen, collapsed: false)
        #expect(expanded == DockLayout(frame: CGRect(x: 0, y: 740, width: 1440, height: 160), placement: .inside, edge: .bottom))
        let collapsed = DockLayoutCalculator.layout(window: full, edge: .bottom, thickness: 160, visibleFrame: screen, collapsed: true)
        #expect(collapsed.frame == CGRect(x: 0, y: 894, width: 1440, height: 6))
    }

    @Test("内侧面板不超过窗口尺寸的 60%")
    func insideLimit() {
        let tall = CGRect(x: 100, y: 100, width: 1240, height: 750) // 上方 75pt、下方 50pt，都放不下
        let layout = DockLayoutCalculator.layout(window: tall, edge: .bottom, thickness: 500, visibleFrame: screen, collapsed: false)
        #expect(layout.placement == .inside)
        #expect(layout.frame.height == 450)
    }

    @Test("折叠只在内侧模式生效")
    func collapsedIgnoredOutside() {
        let layout = DockLayoutCalculator.layout(window: window, edge: .right, thickness: 300, visibleFrame: screen, collapsed: true)
        #expect(layout.placement == .outside && layout.frame.width == 300)
    }

    @Test("多屏：使用窗口所在屏幕的可用区域")
    func multiScreen() {
        // 副屏在主屏右侧
        let secondary = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let windowOnSecondary = CGRect(x: 1500, y: 100, width: 1000, height: 700)
        let layout = DockLayoutCalculator.layout(window: windowOnSecondary, edge: .left, thickness: 300, visibleFrame: secondary, collapsed: false)
        #expect(layout.placement == .outside && layout.edge == .right) // 左侧只有 60pt，换到右侧
        let right = DockLayoutCalculator.layout(window: windowOnSecondary, edge: .right, thickness: 300, visibleFrame: secondary, collapsed: false)
        #expect(right.placement == .outside)
    }
}

@Suite("SnapDetector")
struct SnapDetectorTests {
    let window = CGRect(x: 300, y: 100, width: 800, height: 600)

    @Test("靠近各条边时返回候选（外侧和内侧都可以）", arguments: [
        (CGRect(x: 1110, y: 200, width: 300, height: 300), DockEdge?.some(.right)),   // 外侧，距离 10
        (CGRect(x: 790, y: 200, width: 300, height: 300), DockEdge?.some(.right)),    // 内侧，右边距离 10
        (CGRect(x: 15, y: 200, width: 300, height: 300), DockEdge?.some(.left)),
        (CGRect(x: 400, y: 705, width: 300, height: 100), DockEdge?.some(.bottom)),
        (CGRect(x: 400, y: 10, width: 300, height: 85), DockEdge?.some(.top)),
        (CGRect(x: 1130, y: 200, width: 300, height: 300), DockEdge?.none),           // 距离 30
        (CGRect(x: 1105, y: 800, width: 300, height: 100), DockEdge?.none),           // 垂直方向不重叠
        (CGRect(x: 500, y: 300, width: 200, height: 100), DockEdge?.none),            // 在窗口中间
    ])
    func candidates(panel: CGRect, expected: DockEdge?) {
        #expect(SnapDetector.candidate(panel: panel, window: window) == expected)
    }

    @Test("角落同时靠近两条边时取更近的一条")
    func corner() {
        let panel = CGRect(x: 1105, y: 712, width: 200, height: 100) // 右边距离 5，下边距离 12
        #expect(SnapDetector.candidate(panel: CGRect(x: 1105, y: 650, width: 200, height: 62), window: window) == .right)
        #expect(SnapDetector.candidate(panel: panel, window: window) == nil) // 不重叠时不吸附
        let nearBottom = CGRect(x: 1085, y: 703, width: 200, height: 100) // 下边距离 3，右边（内侧）距离 185
        #expect(SnapDetector.candidate(panel: nearBottom, window: window) == .bottom)
    }

    @Test("贴边面板拖离超过阈值时切换为悬浮")
    func detach() {
        let docked = CGRect(x: 1100, y: 100, width: 300, height: 600)
        #expect(!SnapDetector.isDetached(panel: docked.offsetBy(dx: 15, dy: 0), dockedFrame: docked))
        #expect(SnapDetector.isDetached(panel: docked.offsetBy(dx: 25, dy: 0), dockedFrame: docked))
        #expect(SnapDetector.isDetached(panel: docked.offsetBy(dx: 0, dy: -40), dockedFrame: docked))
    }
}
