import AppKit
import SwiftUI
import TransPeekKit

/// 面板内容（R11；panel-groups G1.5；panel-redesign）。
/// 贴边为 HUD 玻璃样式，悬浮为字幕样式；按钮只在鼠标悬停时显示。单栏和多栏使用同样的栏标题。
struct PanelGroupView: View {
    let window: PanelWindowController

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                PanelBackground(
                    style: window.style,
                    opacity: window.group.opacity,
                    inside: window.dockPlacement == .inside,
                    hovering: window.controlsVisible,
                    collapsedStrip: window.isCollapsedStrip,
                    accent: window.primaryMode.accent
                )

                if window.isCollapsedStrip {
                    Color.clear.accessibilityLabel("\(window.displayName) 的译文面板（已折叠）")
                } else if window.isMultiSection {
                    MultiSectionContent(window: window, size: proxy.size)
                } else if let section = window.visibleSections.first {
                    SectionView(window: window, section: section, size: proxy.size, vertical: true)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: window.isCollapsedStrip ? 3 : PanelBackground.cornerRadius))
            .overlay { ResizeHandles(window: window) }
        }
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - 多栏

private struct MultiSectionContent: View {
    let window: PanelWindowController
    let size: CGSize

    var body: some View {
        let frames = window.sectionFrames(in: size)
        let sections = window.visibleSections
        let items = window.sectionItems
        let vertical = window.isVerticalStack
        ZStack(alignment: .topLeading) {
            ForEach(Array(sections.enumerated()), id: \.element.regionID) { index, section in
                if frames.sections.indices.contains(index) {
                    let frame = frames.sections[index]
                    SectionView(window: window, section: section, size: frame.size, vertical: vertical)
                        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                        .clipped()
                        .offset(x: frame.minX, y: frame.minY)
                }
            }

            // 分隔条只负责显示，拖动由 PanelHostingView 处理（G2.1）
            ForEach(Array(frames.dividers.enumerated()), id: \.offset) { index, rect in
                SectionDivider(
                    style: window.style,
                    vertical: vertical,
                    showsGrip: window.controlsVisible && SectionLayout.isDraggable(divider: index, items: items)
                )
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

private struct SectionDivider: View {
    let style: PanelStyle
    let vertical: Bool
    let showsGrip: Bool

    var body: some View {
        ZStack {
            switch style {
            case .hud:
                Rectangle()
                    .fill(.white.opacity(0.08))
                    .frame(width: vertical ? nil : 0.5, height: vertical ? 0.5 : nil)
            case .subtitle:
                Line(vertical: vertical)
                    .stroke(.white.opacity(0.18), style: StrokeStyle(lineWidth: 0.75, dash: [3, 4]))
                    .frame(width: vertical ? nil : 1, height: vertical ? 1 : nil)
                    .padding(vertical ? .horizontal : .vertical, 12)
            }
            Capsule()
                .fill(.white.opacity(0.3))
                .frame(width: vertical ? 30 : 4, height: vertical ? 4 : 30)
                .opacity(showsGrip ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: showsGrip)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct Line: Shape {
        let vertical: Bool
        func path(in rect: CGRect) -> Path {
            var path = Path()
            if vertical {
                path.move(to: CGPoint(x: rect.minX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            } else {
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            }
            return path
        }
    }
}

// MARK: - 栏

private struct SectionView: View {
    let window: PanelWindowController
    let section: SectionController
    let size: CGSize
    /// 栏上下排列。左右排列时折叠的栏是一条竖条。
    let vertical: Bool

    var body: some View {
        if section.isCollapsed && !vertical {
            CollapsedColumn(window: window, section: section)
        } else {
            VStack(spacing: 0) {
                SectionHeader(window: window, section: section)
                if !section.isCollapsed {
                    if section.isShowingTextTools, !window.isLocked {
                        TextTools(section: section, style: window.style)
                    }
                    // 每栏单独判断是否精简显示（R10.6、G2.5）
                    SectionBody(section: section, style: window.style, compact: size.height < 80)
                }
            }
        }
    }
}

/// 栏标题（P4）：左侧标识和名称，右侧悬停时显示的按钮。整条可以拖动面板；已折叠时点击展开（P4.6）。
private struct SectionHeader: View {
    let window: PanelWindowController
    let section: SectionController

    private var style: PanelStyle { window.style }
    private var showsCollapse: Bool { window.isMultiSection }

    var body: some View {
        ZStack {
            // 底层：拖动面板 / 点击展开
            Color.clear
                .contentShape(Rectangle())
                .modifier(PanelDragModifier(window: window, onTap: section.isCollapsed ? { window.toggleSectionCollapsed(section) } : nil))

            HStack(spacing: 4) {
                if showsCollapse {
                    CollapseButton(window: window, section: section)
                        .opacity(window.controlsVisible || section.isCollapsed ? 1 : 0)
                        .allowsHitTesting(window.controlsVisible || section.isCollapsed)
                }
                HStack(spacing: 6) {
                    SectionTitleLabel(name: section.regionName, mode: section.mode, style: style)
                    if section.isTargetClosed {
                        StatusBadge(text: "窗口已关闭", color: .orange)
                    }
                    if section.isCollapsed, section.collapsedUnread > 0 {
                        NewCountBadge(count: section.collapsedUnread, accent: section.mode.accent)
                    }
                }
                .allowsHitTesting(false)
                Spacer(minLength: 4)
                HeaderButtons(window: window, section: section)
                    .opacity(window.controlsVisible ? 1 : 0)
                    .allowsHitTesting(window.controlsVisible)
            }
            .padding(.leading, showsCollapse ? 6 : 12)
            .padding(.trailing, 8)
        }
        .frame(height: SectionLayout.headerSize)
        .animation(.easeOut(duration: 0.15), value: window.controlsVisible)
        .help(section.isCollapsed ? "点击展开；拖动移动面板" : "拖动移动面板，靠近窗口边缘松开可贴边")
    }
}

private struct HeaderButtons: View {
    let window: PanelWindowController
    let section: SectionController

    var body: some View {
        HStack(spacing: 3) {
            if !section.isCollapsed {
                HeaderButton(label: "字号与原文", isOn: section.isShowingTextTools) {
                    Text("Aa").font(.system(size: 10.5, weight: .semibold))
                } action: {
                    section.toggleTextTools()
                }
            }
            SectionMenu(window: window, section: section)
            HeaderButton(label: window.isMultiSection ? "关闭这一栏并暂停区域" : "关闭面板并暂停区域") {
                Image(systemName: "xmark").font(.system(size: 9.5, weight: .semibold))
            } action: {
                window.closeSection(section.regionID)
            }
        }
    }
}

/// 22×20 的圆角方块按钮。
private struct HeaderButton<Label: View>: View {
    let label: String
    var isOn = false
    @ViewBuilder let content: () -> Label
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            content()
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(isOn ? 0.2 : 0.1)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.85))
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct CollapseButton: View {
    let window: PanelWindowController
    let section: SectionController

    var body: some View {
        let collapsed = section.isCollapsed
        let enabled = !window.isLocked && (collapsed || window.canCollapse(section.regionID))
        Button {
            window.toggleSectionCollapsed(section)
        } label: {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 16, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.6))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(collapsed ? "展开这一栏" : (enabled ? "折叠这一栏（继续识别）" : "至少保留一栏展开"))
        .accessibilityLabel(collapsed ? "展开 \(section.regionName)" : "折叠 \(section.regionName)")
    }
}

private struct NewCountBadge: View {
    let count: Int
    let accent: Color

    var body: some View {
        Text("\(count) 条新消息")
            .font(.system(size: 9.5, weight: .bold))
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(accent))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
    }
}

/// 左右排列时折叠的栏：竖条，点击展开（G3.2、G3.3、P4.6）。
private struct CollapsedColumn: View {
    let window: PanelWindowController
    let section: SectionController

    var body: some View {
        Button {
            window.toggleSectionCollapsed(section)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                Circle().fill(section.mode.accent).frame(width: 7, height: 7)
                if section.collapsedUnread > 0 {
                    Text("\(section.collapsedUnread)")
                        .font(.system(size: 9.5, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(section.mode.accent))
                        .foregroundStyle(.white)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(window.isLocked)
        .help("\(section.regionName)：点击展开")
        .accessibilityLabel("展开 \(section.regionName)")
    }
}

/// 拖动标题移动面板（R10.1）。`onTap` 不为空时，没有移动的点击交给它（已折叠的栏点击展开）。
private struct PanelDragModifier: ViewModifier {
    let window: PanelWindowController
    var onTap: (() -> Void)?
    @State private var isDragging = false

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isDragging {
                        guard hypot(value.translation.width, value.translation.height) >= 2 else { return }
                        isDragging = true
                        window.beginDrag()
                    }
                    window.drag()
                }
                .onEnded { _ in
                    if isDragging {
                        isDragging = false
                        window.endDrag()
                    } else {
                        onTap?()
                    }
                }
        )
    }
}

/// “Aa”工具条：字号和显示原文（P4.3）。
private struct TextTools: View {
    let section: SectionController
    let style: PanelStyle

    var body: some View {
        HStack(spacing: 6) {
            ToolButton(label: "缩小字号") {
                Text("A−").font(.system(size: 10.5, weight: .semibold))
            } action: { section.adjustFontSize(by: -1) }
            .disabled(section.config.fontSize <= PanelConfig.fontSizeRange.lowerBound)
            Text("\(Int(section.config.fontSize))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
                .frame(minWidth: 18)
                .accessibilityLabel("字号 \(Int(section.config.fontSize)) 点")
            ToolButton(label: "放大字号") {
                Text("A+").font(.system(size: 12.5, weight: .semibold))
            } action: { section.adjustFontSize(by: 1) }
            .disabled(section.config.fontSize >= PanelConfig.fontSizeRange.upperBound)
            Rectangle().fill(.white.opacity(0.12)).frame(width: 0.5, height: 14)
            Button {
                section.toggleOriginal()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: section.config.showsOriginal ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 10))
                        .foregroundStyle(section.config.showsOriginal ? section.mode.accent : .white.opacity(0.5))
                    Text("原文").font(.system(size: 11))
                }
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.1)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.85))
            .accessibilityLabel(section.config.showsOriginal ? "隐藏原文" : "显示原文")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.white.opacity(style == .hud ? 0.04 : 0.08))
    }

    private struct ToolButton<Label: View>: View {
        let label: String
        @ViewBuilder let content: () -> Label
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                content()
                    .frame(width: 26, height: 20)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.1)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.85))
            .help(label)
            .accessibilityLabel(label)
        }
    }
}

// MARK: - 菜单（G3.1、G4.3、G4.4、P4.4）

private struct SectionMenu: View {
    let window: PanelWindowController
    let section: SectionController

    var body: some View {
        Menu {
            SectionMenuItems(window: window, section: section)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22, height: 20)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.1)))
        .foregroundStyle(.white.opacity(0.85))
        .help("更多")
        .accessibilityLabel("\(section.regionName) 的更多选项")
    }
}

private struct SectionMenuItems: View {
    let window: PanelWindowController
    let section: SectionController

    var body: some View {
        let others = window.otherPanels()
        if window.isMultiSection {
            Button(section.isCollapsed ? "展开" : "折叠") { window.toggleSectionCollapsed(section) }
                .disabled(!section.isCollapsed && !window.canCollapse(section.regionID))
            Button("上移") { window.moveSection(section.regionID, direction: -1) }
                .disabled(window.neighborOffset(of: section.regionID, direction: -1) == nil)
            Button("下移") { window.moveSection(section.regionID, direction: 1) }
                .disabled(window.neighborOffset(of: section.regionID, direction: 1) == nil)
            Button("移到新面板") { window.moveToNewPanel(section.regionID) }
        }
        if !others.isEmpty {
            Menu("移到") {
                ForEach(others) { choice in
                    Button(choice.name) { window.moveRegion(section.regionID, to: choice.id) }
                }
            }
        }
        if window.isMultiSection || !others.isEmpty { Divider() }
        Button("复制全部") { section.copyAll() }
        Button("清空历史") { section.clearHistory() }

        Section("面板") {
            Menu("位置") {
                ForEach(DockEdge.allCases, id: \.self) { edge in
                    Button("贴合\(edge.displayName)边") { window.dock(to: edge) }
                }
                Button("悬浮") { window.float() }
                if window.dockPlacement == .inside {
                    Divider()
                    Button(window.group.collapsedStrip ? "取消折叠" : "折叠为细边") { window.toggleCollapsedStrip() }
                }
            }
            Menu("背景不透明度") {
                ForEach([1.0, 0.85, 0.7, 0.5, 0.3], id: \.self) { value in
                    Button {
                        window.setOpacity(value)
                    } label: {
                        if abs(window.group.opacity - value) < 0.01 {
                            Label("\(Int(value * 100))%", systemImage: "checkmark")
                        } else {
                            Text("\(Int(value * 100))%")
                        }
                    }
                }
            }
            if !others.isEmpty {
                Menu("合并到") {
                    ForEach(others) { choice in
                        Button(choice.name) { window.merge(into: choice.id) }
                    }
                }
            }
            if window.isMultiSection {
                Button("关闭面板（暂停其中所有区域）") { window.closeAll() }
            }
        }
    }
}

// MARK: - 栏内容

private struct SectionBody: View {
    let section: SectionController
    let style: PanelStyle
    let compact: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 未配置翻译服务时只显示原文，并提示去设置（R8.3、P7.2）
            if let reason = section.unavailableReason, !compact {
                Button {
                    section.onOpenSettings?()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "key.slash").font(.system(size: 9.5))
                        Text(reason).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text("去设置 ›").fontWeight(.semibold)
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 12)
                    .frame(height: 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.yellow.opacity(style == .hud ? 0.15 : 0.25))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("打开设置中的翻译服务")
            }
            if compact {
                CompactView(section: section, style: style)
            } else if section.mode == .dialog {
                switch style {
                case .hud: HUDDialogView(section: section)
                case .subtitle: SubtitleDialogView(section: section)
                }
            } else {
                EntryList(section: section, style: style)
            }
        }
    }
}

private struct EntryList: View {
    let section: SectionController
    let style: PanelStyle
    private let bottomID = "bottom"

    var body: some View {
        let items = section.displayItems
        if items.isEmpty {
            SectionPlaceholder(section: section, style: style)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: style == .hud ? 10 : 6) {
                        ForEach(items) { item in
                            ChatItemRow(item: item, section: section, style: style).id(item.id)
                        }
                        Color.clear.frame(height: 1).id(bottomID)
                            .onAppear { section.bottomMarkerVisible(true) }
                            .onDisappear { section.bottomMarkerVisible(false) }
                    }
                    .padding(.leading, style == .hud ? 6 : 12)
                    .padding(.trailing, 12)
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.never)
                .onAppear {
                    // 展开折叠的栏、切换样式、从精简显示恢复时，回到底部（G3.2）
                    guard section.isAtBottom else { return }
                    section.didScrollToBottom()
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
                .onChange(of: section.appendCounter) {
                    guard section.isAtBottom else { return }
                    section.didScrollToBottom()
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
                .overlay(alignment: .bottom) {
                    if section.unreadCount > 0 {
                        Button {
                            section.didScrollToBottom()
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        } label: {
                            Text("↓ \(section.unreadCount) 条新消息")
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Capsule().fill(section.mode.accent))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 8)
                    }
                }
            }
        }
    }
}

/// HUD 样式的对话：当前文本卡片，之前的对话默认收起（P2.4）。
private struct HUDDialogView: View {
    let section: SectionController

    var body: some View {
        if let current = section.history.currentDialog {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Rectangle().fill(section.mode.accent).frame(width: 3)
                    VStack(alignment: .leading, spacing: 4) {
                        EntryPrimaryText(entry: current, section: section, fontSize: section.config.fontSize * 1.15, weight: .medium)
                        if section.config.showsOriginal, let translated = current.translation.translatedText, translated != current.original {
                            Text(current.original)
                                .font(.system(size: section.config.fontSize * 0.8))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true) // 边条不撑满整栏高度
                .background(.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .contextMenu { EntryContextMenu(entry: current, section: section) }
                .padding(.horizontal, 10)
                .padding(.top, 4)

                let history = section.history.entries.filter { $0.kind != .gapMarker }
                if !history.isEmpty {
                    Button {
                        section.toggleDialogHistory()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: section.isDialogHistoryExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                            Text("之前的对话 \(history.count)")
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 14)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if section.isDialogHistoryExpanded {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(history.reversed()) { entry in
                                    ChatItemRow(item: DisplayItem(entry: entry, speaker: nil, isLatest: false), section: section, style: .hud)
                                        .opacity(0.75)
                                }
                            }
                            .padding(.leading, 6).padding(.trailing, 12).padding(.bottom, 8)
                        }
                        .scrollIndicators(.never)
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            SectionPlaceholder(section: section, style: .hud)
        }
    }
}

/// 字幕样式的对话：居中显示当前文本，不显示历史（P3.4）。
private struct SubtitleDialogView: View {
    let section: SectionController

    var body: some View {
        if let current = section.history.currentDialog {
            VStack(spacing: 5) {
                EntryPrimaryText(entry: current, section: section, fontSize: section.config.fontSize * 1.25, weight: .semibold, alignment: .center)
                if section.config.showsOriginal, let translated = current.translation.translatedText, translated != current.original {
                    Text(current.original)
                        .font(.system(size: section.config.fontSize * 0.85))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                }
            }
            .subtitleShadow(.subtitle)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .contextMenu { EntryContextMenu(entry: current, section: section) }
        } else {
            SectionPlaceholder(section: section, style: .subtitle)
        }
    }
}

/// 空间不足时只显示最新一条（R10.6、G2.5、P8.2）。
private struct CompactView: View {
    let section: SectionController
    let style: PanelStyle

    var body: some View {
        let latest = section.history.currentDialog ?? section.displayItems.last { $0.entry.kind != .gapMarker }?.entry
        Group {
            if let latest {
                Text(latest.translation.translatedText ?? latest.original)
                    .font(.system(size: section.config.fontSize, weight: style == .subtitle ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(2)
                    .subtitleShadow(style)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            } else {
                SectionPlaceholder(section: section, style: style, compact: true)
            }
        }
    }
}

// MARK: - 调整大小提示

/// 只负责显示可拖动的位置，实际拖动由 `PanelHostingView` 在 AppKit 层处理（R9.1、R10.1）。悬停时显示（P3.5）。
private struct ResizeHandles: View {
    let window: PanelWindowController

    var body: some View {
        if !window.isCollapsedStrip {
            GeometryReader { proxy in
                if case .floating = window.group.placement {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .position(x: proxy.size.width - 9, y: proxy.size.height - 9)
                } else if let side = window.thicknessHandleSide {
                    let horizontal = side.isHorizontal
                    Capsule()
                        .fill(.white.opacity(0.4))
                        .frame(width: horizontal ? 36 : 3, height: horizontal ? 3 : 36)
                        .position(gripPosition(side, proxy.size))
                }
            }
            .opacity(window.controlsVisible ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: window.controlsVisible)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func gripPosition(_ side: DockEdge, _ size: CGSize) -> CGPoint {
        switch side {
        case .left: CGPoint(x: 3, y: size.height / 2)
        case .right: CGPoint(x: size.width - 3, y: size.height / 2)
        case .top: CGPoint(x: size.width / 2, y: 3)
        case .bottom: CGPoint(x: size.width / 2, y: size.height - 3)
        }
    }
}
