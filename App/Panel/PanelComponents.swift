import AppKit
import SwiftUI
import TransPeekKit

// 面板和设置预览共用的外观组件（panel-redesign design.md「App 层」）。

// MARK: - 标识色（P6）

extension RegionMode {
    /// 聊天蓝、对话橙、单次绿。
    var accent: Color {
        switch self {
        case .chat: Color(nsColor: .systemBlue)
        case .dialog: Color(nsColor: .systemOrange)
        case .once: Color(nsColor: .systemGreen)
        }
    }

    /// 深色背景上的浅色变体：说话人标签等小字（P5.1）。
    var accentLight: Color {
        let base: NSColor = switch self {
        case .chat: .systemBlue
        case .dialog: .systemOrange
        case .once: .systemGreen
        }
        return Color(nsColor: base.blended(withFraction: 0.45, of: .white) ?? base)
    }
}

// MARK: - 背景（P1、P2.1、P3.1）

/// 系统毛玻璃。面板永远不是 key 窗口，`state` 必须为 `.active`，否则显示为非活跃的灰色。
/// 不参与命中测试，点击交给 SwiftUI 内容和 `PanelHostingView`。
struct VisualEffectBackground: NSViewRepresentable {
    var cornerRadius: CGFloat
    /// 设置中的预览模糊窗口内的示例画面，面板模糊窗口后面的游戏画面。
    var withinWindow = false

    final class PassthroughEffectView: NSVisualEffectView {
        var radius: CGFloat = -1
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> PassthroughEffectView {
        let view = PassthroughEffectView()
        view.material = .hudWindow
        view.blendingMode = withinWindow ? .withinWindow : .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: PassthroughEffectView, context: Context) {
        guard view.radius != cornerRadius else { return }
        view.radius = cornerRadius
        // SwiftUI 的 clipShape 不能裁剪 AppKit 视图，用可拉伸的圆角遮罩
        view.maskImage = Self.mask(cornerRadius)
    }

    static func mask(_ radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

struct PanelBackground: View {
    let style: PanelStyle
    let opacity: Double
    var inside = false
    var hovering = false
    var collapsedStrip = false
    var accent: Color = .accentColor
    var withinWindow = false

    static let cornerRadius: CGFloat = 12

    var body: some View {
        let tint = style.backgroundOpacity(opacity, inside: inside, hovering: hovering)
        if collapsedStrip {
            // 折叠细边使用第一栏的标识色（P1.4）
            RoundedRectangle(cornerRadius: 3).fill(accent.opacity(0.75))
        } else {
            switch style {
            case .hud:
                ZStack {
                    VisualEffectBackground(cornerRadius: Self.cornerRadius, withinWindow: withinWindow)
                    RoundedRectangle(cornerRadius: Self.cornerRadius)
                        .fill(Color(red: 0x14 / 255, green: 0x17 / 255, blue: 0x1D / 255).opacity(tint))
                    RoundedRectangle(cornerRadius: Self.cornerRadius)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                }
            case .subtitle:
                ZStack {
                    RoundedRectangle(cornerRadius: Self.cornerRadius).fill(.black.opacity(tint))
                    if hovering {
                        RoundedRectangle(cornerRadius: Self.cornerRadius).strokeBorder(.white.opacity(0.18), lineWidth: 1)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: hovering)
            }
        }
    }
}

// MARK: - 字幕描边（P3.1）

/// 两层阴影模拟描边，在亮色和暗色画面上都能看清。只在字幕样式中生效。
struct SubtitleShadow: ViewModifier {
    let style: PanelStyle

    func body(content: Content) -> some View {
        if style == .subtitle {
            content
                .shadow(color: .black.opacity(0.9), radius: 1, x: 0, y: 1)
                .shadow(color: .black.opacity(0.6), radius: 3)
        } else {
            content
        }
    }
}

extension View {
    func subtitleShadow(_ style: PanelStyle) -> some View {
        modifier(SubtitleShadow(style: style))
    }
}

// MARK: - 栏标题的静态部分

/// 标识色圆点、名称、模式（P2.2）；字幕样式只有弱化的名称（P3.1）。
struct SectionTitleLabel: View {
    let name: String
    let mode: RegionMode
    let style: PanelStyle

    var body: some View {
        switch style {
        case .hud:
            HStack(spacing: 6) {
                Circle().fill(mode.accent).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(name).font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.95)).lineLimit(1)
                Text(mode.displayName).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
        case .subtitle:
            Text(name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .subtitleShadow(style)
                .accessibilityLabel("\(name)，\(mode.displayName)")
        }
    }
}

// MARK: - 条目（P2.3、P3.2、P3.3、P5、P7.3）

struct ChatItemRow: View {
    let item: DisplayItem
    let section: SectionController
    let style: PanelStyle

    private var entry: Entry { item.entry }
    private var fontSize: CGFloat { section.config.fontSize }
    private var accent: Color { section.mode.accent }

    var body: some View {
        Group {
            if entry.kind == .gapMarker {
                GapMarkerRow()
            } else {
                switch style {
                case .hud: hudRow
                case .subtitle: subtitleRow
                }
            }
        }
        .contextMenu { EntryContextMenu(entry: entry, section: section) }
    }

    private var hudRow: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.25)
                .fill(item.isLatest ? accent : .clear)
                .frame(width: 2.5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let speaker = item.speaker {
                    Text(speaker)
                        .font(.system(size: fontSize * 0.75, weight: .semibold))
                        .foregroundStyle(section.mode.accentLight)
                        .lineLimit(1)
                }
                EntryPrimaryText(entry: entry, section: section, fontSize: fontSize, weight: .regular, color: .white.opacity(0.95))
                if section.config.showsOriginal, showsOriginalLine {
                    Text(entry.original)
                        .font(.system(size: fontSize * 0.8))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true) // 竖条只和内容一样高
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var subtitleRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let speaker = item.speaker {
                    Text(speaker)
                        .font(.system(size: fontSize * 0.75, weight: .semibold))
                        .foregroundStyle(section.mode.accentLight)
                        .lineLimit(1)
                        .fixedSize()
                }
                EntryPrimaryText(entry: entry, section: section, fontSize: fontSize, weight: item.isLatest ? .semibold : .regular, color: .white)
            }
            // 原文只显示在最新一条下方（P3.3）
            if item.isLatest, section.config.showsOriginal, showsOriginalLine {
                Text(entry.original)
                    .font(.system(size: fontSize * 0.8))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .subtitleShadow(style)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var showsOriginalLine: Bool {
        if let translated = entry.translation.translatedText { return translated != entry.original }
        return false
    }
}

/// 译文，以及翻译中、失败、已回退、未配置服务时的显示（P7.3）。
struct EntryPrimaryText: View {
    let entry: Entry
    let section: SectionController
    let fontSize: CGFloat
    var weight: Font.Weight = .regular
    var color: Color = .white
    var alignment: TextAlignment = .leading

    var body: some View {
        switch entry.translation {
        case .pending:
            Text(entry.original)
                .font(.system(size: fontSize, weight: weight))
                .foregroundStyle(color.opacity(0.55))
                .multilineTextAlignment(alignment)
                .accessibilityLabel("翻译中：\(entry.original)")
        case let .done(text, fallback):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(text)
                    .font(.system(size: fontSize, weight: weight))
                    .foregroundStyle(color)
                    .multilineTextAlignment(alignment)
                if fallback {
                    StatusBadge(text: "已回退", color: .yellow)
                        .help("LLM 翻译失败，已改用 Google 翻译")
                }
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.original)
                    .font(.system(size: fontSize, weight: weight))
                    .foregroundStyle(color)
                    .multilineTextAlignment(alignment)
                HStack(spacing: 6) {
                    StatusBadge(text: "翻译失败", color: .orange)
                    Button("重试") { section.retry(entry) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .systemBlue).opacity(0.9))
                }
                .help(message)
            }
        case .unavailable, .metadata:
            Text(entry.original)
                .font(.system(size: fontSize, weight: weight))
                .foregroundStyle(color)
                .multilineTextAlignment(alignment)
        case .hidden:
            EmptyView()
        }
    }
}

struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.22)))
            .foregroundStyle(color)
            .fixedSize()
    }
}

struct GapMarkerRow: View {
    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(.orange.opacity(0.45)).frame(height: 0.5)
            Text("可能有遗漏").font(.system(size: 10)).foregroundStyle(.orange.opacity(0.85)).fixedSize()
            Rectangle().fill(.orange.opacity(0.45)).frame(height: 0.5)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct EntryContextMenu: View {
    let entry: Entry
    let section: SectionController

    var body: some View {
        if entry.kind != .gapMarker {
            if let translated = entry.translation.translatedText {
                Button("复制译文") { section.copy(translated) }
            }
            Button("复制原文") { section.copy(entry.original) }
        }
        Button("复制全部") { section.copyAll() }
        if case .failed = entry.translation {
            Button("重试翻译") { section.retry(entry) }
        }
        Divider()
        Button("清空历史") { section.clearHistory() }
    }
}

// MARK: - 状态提示（P7.1）

struct SectionPlaceholder: View {
    let section: SectionController
    let style: PanelStyle
    var compact = false

    var body: some View {
        Group {
            if compact {
                Text(message).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            } else {
                VStack(spacing: 7) {
                    if section.isPreparingOCR && !section.isTargetClosed && !section.isPaused {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: symbol).font(.system(size: 20, weight: .light))
                    }
                    Text(message).font(.system(size: 12)).multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 12)
            }
        }
        .subtitleShadow(style)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var message: String {
        if section.isTargetClosed { return "目标窗口已关闭" }
        if section.isPaused { return "已暂停" }
        if section.isPreparingOCR { return "正在加载文字识别模型，首次运行约需半分钟…" }
        return section.mode == .once ? "按 ⌃⌥R 识别" : "等待识别…"
    }

    private var symbol: String {
        if section.isTargetClosed { return "xmark.rectangle" }
        if section.isPaused { return "pause.circle" }
        return section.mode == .once ? "command" : "text.viewfinder"
    }
}
