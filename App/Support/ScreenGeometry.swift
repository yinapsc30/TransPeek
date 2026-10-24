import AppKit

/// CG 全局坐标（原点在主屏左上角，y 向下）与 Cocoa 坐标（原点在主屏左下角，y 向上）的转换。
/// WindowTracker 和布局计算使用 CG 坐标，NSWindow 使用 Cocoa 坐标（design.md「贴边布局计算」）。
@MainActor
enum ScreenGeometry {
    /// 主屏（含菜单栏的屏幕）高度。
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    static func cocoa(fromCG rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func cg(fromCocoa rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// 与 CG 矩形重叠面积最大的屏幕。
    static func screen(containingCG rect: CGRect) -> NSScreen? {
        let cocoaRect = cocoa(fromCG: rect)
        return NSScreen.screens.max { lhs, rhs in
            area(lhs.frame.intersection(cocoaRect)) < area(rhs.frame.intersection(cocoaRect))
        } ?? NSScreen.main
    }

    /// 窗口所在屏幕的可用区域（CG 坐标）。
    static func visibleFrameCG(for windowCG: CGRect) -> CGRect {
        guard let screen = screen(containingCG: windowCG) else { return windowCG }
        return cg(fromCocoa: screen.visibleFrame)
    }

    static func screenFrameCG(for windowCG: CGRect) -> CGRect {
        guard let screen = screen(containingCG: windowCG) else { return windowCG }
        return cg(fromCocoa: screen.frame)
    }

    static func backingScale(forCG rect: CGRect) -> CGFloat {
        screen(containingCG: rect)?.backingScaleFactor ?? 2
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}
