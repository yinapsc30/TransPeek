import AppKit

/// 框选区域：在目标窗口所在屏幕上显示遮罩，拖拽绘制矩形（R4.1、R4.6）。
@MainActor
final class RegionSelector {
    private var window: SelectionOverlayWindow?

    var isActive: Bool { window != nil }

    /// - Parameters:
    ///   - targetFrame: 目标窗口 frame（CG 坐标）。
    ///   - completion: 返回相对目标窗口的归一化矩形，取消时为 `nil`。
    func begin(targetFrame: CGRect, completion: @escaping (CGRect?) -> Void) {
        cancel()
        let screenFrameCG = ScreenGeometry.screenFrameCG(for: targetFrame)
        let window = SelectionOverlayWindow(contentRect: ScreenGeometry.cocoa(fromCG: screenFrameCG))
        let targetInView = targetFrame.offsetBy(dx: -screenFrameCG.minX, dy: -screenFrameCG.minY)
        let view = SelectionOverlayView(frame: CGRect(origin: .zero, size: screenFrameCG.size), target: targetInView)
        view.onFinish = { [weak self] rectInView in
            self?.finish()
            guard let rectInView else { completion(nil); return }
            let rectCG = rectInView.offsetBy(dx: screenFrameCG.minX, dy: screenFrameCG.minY)
            completion(rectCG.normalized(in: targetFrame))
        }
        window.contentView = view
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    func cancel() {
        finish()
    }

    private func finish() {
        window?.orderOut(nil)
        window = nil
    }
}

final class SelectionOverlayWindow: NSWindow {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        // 全屏游戏所在的桌面中也能显示
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool { true }
}

/// 遮罩视图。使用左上原点坐标（isFlipped），与 CG 坐标一致。
final class SelectionOverlayView: NSView {
    var onFinish: ((CGRect?) -> Void)?

    private let target: CGRect
    private var start: CGPoint?
    private var selection: CGRect?
    private let minimumSize: CGFloat = 12

    init(frame: CGRect, target: CGRect) {
        self.target = target
        super.init(frame: frame)
        setAccessibilityRole(.group)
        setAccessibilityLabel("框选区域：拖拽框选要翻译的区域，按 Esc 取消")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        // 目标窗口外加深遮罩，窗口内轻遮罩，选区内透明
        NSColor.black.withAlphaComponent(0.5).setFill()
        let outer = NSBezierPath(rect: bounds)
        outer.append(NSBezierPath(rect: target))
        outer.windingRule = .evenOdd
        outer.fill()

        NSColor.black.withAlphaComponent(0.2).setFill()
        let inner = NSBezierPath(rect: target)
        if let selection {
            inner.append(NSBezierPath(rect: selection))
            inner.windingRule = .evenOdd
        }
        inner.fill()

        NSColor.white.withAlphaComponent(0.6).setStroke()
        let targetBorder = NSBezierPath(rect: target.insetBy(dx: 0.5, dy: 0.5))
        targetBorder.lineWidth = 1
        targetBorder.stroke()

        if let selection {
            NSColor.systemBlue.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: 1, dy: 1))
            border.lineWidth = 2
            border.setLineDash([6, 4], count: 2, phase: 0)
            border.stroke()
            drawLabel("\(Int(selection.width)) × \(Int(selection.height))", at: CGPoint(x: selection.minX, y: selection.maxY + 6))
        }

        drawLabel("拖拽框选要翻译的区域，按 Esc 取消", at: CGPoint(x: target.minX + 12, y: max(target.minY + 12, 12)))
    }

    private func drawLabel(_ text: String, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let background = CGRect(x: point.x, y: point.y, width: size.width + 16, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: background, xRadius: 6, yRadius: 6).fill()
        string.draw(at: CGPoint(x: point.x + 8, y: point.y + 4))
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, target.minX), target.maxX), y: min(max(point.y, target.minY), target.maxY))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard target.contains(point) else { return }
        start = point
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = clamp(convert(event.locationInWindow, from: nil))
        selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { start = nil }
        guard let selection, selection.width >= minimumSize, selection.height >= minimumSize else {
            self.selection = nil
            needsDisplay = true
            return
        }
        onFinish?(selection)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onFinish?(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onFinish?(nil)
    }
}
