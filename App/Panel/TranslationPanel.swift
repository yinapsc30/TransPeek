import AppKit
import SwiftUI
import TransPeekKit

/// 译文面板窗口（design.md「窗口层」）。
///
/// - 不抢焦点：nonactivating、不能成为 key/main 窗口，显示和更新不会让目标应用失去前台（R11.6）。
/// - 在所有桌面和全屏桌面中可见，显示/隐藏由目标窗口状态控制（R12.1、R3.5）。
/// - 无边框，移动和调整大小由面板自己的标题栏和拖拽手柄处理，便于实现吸附和贴边厚度调整。
final class TranslationPanel: NSPanel {
    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 320, height: 400), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 面板的内容视图：
/// - 第一次点击就响应（面板不是 key 窗口）。
/// - 不让 SwiftUI 内容反过来约束窗口尺寸，窗口大小完全由 PanelWindowController 控制。
/// - 鼠标进出和移动用 `.activeAlways` 跟踪：游戏在前台、TransPeek 不是活跃应用时也能触发
///   （折叠面板的悬停展开、调整大小的光标）。
/// - 调整大小在 AppKit 层处理（R9.1、R10.1）：边缘区域的点击不交给 SwiftUI，直接由本视图跟踪拖动。
///   SwiftUI 的悬停和手势在非 key 窗口、后台应用中不可靠。
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChange: ((Bool) -> Void)?
    /// 返回某个点（原点左上）可以拖动的边，`nil` 表示不在调整大小区域。
    var resizeEdges: ((CGPoint, CGSize) -> Set<DockEdge>?)?
    var onResizeBegin: ((Set<DockEdge>) -> Void)?
    var onResize: (() -> Void)?
    var onResizeEnd: (() -> Void)?
    /// 鼠标在面板中按下（用于记录当前面板，G4.2）。
    var onMouseDown: (() -> Void)?
    /// 返回某个点（原点左上）所在的可拖动分隔条序号（panel-groups G2.1）。
    var dividerAt: ((CGPoint, CGSize) -> Int?)?
    /// 栏是否上下排列（分隔条上下拖动）。
    var dividerIsVertical: (() -> Bool)?
    var onDividerBegin: ((Int, CGSize) -> Void)?
    /// 参数为分隔条移动的距离，向下（或向右）为正。
    var onDividerDrag: ((CGFloat) -> Void)?
    var onDividerEnd: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isResizing = false

    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private func topLeftPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return isFlipped ? point : CGPoint(x: point.x, y: bounds.height - point.y)
    }

    private func edges(at point: CGPoint) -> Set<DockEdge>? {
        resizeEdges?(point, bounds.size)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // hitTest 的参数在父视图坐标系中
        let local = convert(point, from: superview)
        let topLeft = isFlipped ? local : CGPoint(x: local.x, y: bounds.height - local.y)
        if bounds.contains(local), edges(at: topLeft) != nil || dividerAt?(topLeft, bounds.size) != nil { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        let point = topLeftPoint(event)
        if edges(at: point) == nil, let divider = dividerAt?(point, bounds.size) {
            trackDivider(divider)
            return
        }
        guard let edges = edges(at: point) else {
            super.mouseDown(with: event)
            return
        }
        isResizing = true
        onResizeBegin?(edges)
        // 自己跟踪拖动，直到松开鼠标
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            onResize?()
            Self.cursor(for: edges).set()
        }
        isResizing = false
        onResizeEnd?()
    }

    /// 拖动栏之间的分隔条，直到松开鼠标（G2.1）。
    private func trackDivider(_ index: Int) {
        let vertical = dividerIsVertical?() ?? true
        let cursor: NSCursor = vertical ? .resizeUpDown : .resizeLeftRight
        let start = NSEvent.mouseLocation
        isResizing = true
        onDividerBegin?(index, bounds.size)
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let mouse = NSEvent.mouseLocation
            // 屏幕坐标 y 向上，面板内容 y 向下
            onDividerDrag?(vertical ? start.y - mouse.y : mouse.x - start.x)
            cursor.set()
        }
        isResizing = false
        onDividerEnd?()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard !isResizing else { return }
        let point = topLeftPoint(event)
        if let edges = edges(at: point) {
            Self.cursor(for: edges).set()
        } else if dividerAt?(point, bounds.size) != nil {
            ((dividerIsVertical?() ?? true) ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if !isResizing { NSCursor.arrow.set() }
        onHoverChange?(false)
    }

    static func cursor(for edges: Set<DockEdge>) -> NSCursor {
        if edges.count > 1 { return .crosshair }
        return edges.contains(.left) || edges.contains(.right) ? .resizeLeftRight : .resizeUpDown
    }
}

/// 拖动悬浮面板靠近窗口边缘时显示的吸附预览（R10.3）。
final class SnapPreviewWindow: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true
        isOpaque = false
        hasShadow = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.22).cgColor
        view.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.8).cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 10
        contentView = view
    }

    override var canBecomeKey: Bool { false }
}
