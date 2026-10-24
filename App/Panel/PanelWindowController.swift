import AppKit
import Observation
import SwiftUI
import TransPeekKit

/// 面板上可拖拽调整大小的手柄。
enum PanelResizeHandle: Hashable {
    /// 悬浮模式：拖动的边，右下角为 `[.right, .bottom]`（R10.1）。
    case floating(Set<DockEdge>)
    /// 贴边模式调整厚度，参数为被拖动的面板边（R9.1）。
    case thickness(DockEdge)

    static let corner = PanelResizeHandle.floating([.right, .bottom])
}

/// 菜单中可选的其他面板（G4.3、G4.4）。
struct PanelChoice: Identifiable, Hashable {
    let id: UUID
    let name: String
}

/// 需要由 `SessionCoordinator` 处理的面板操作（会改变面板结构或区域状态）。
enum PanelCommand {
    /// 用户操作了该面板，记为当前面板（G4.2）。
    case activate
    /// 关闭一栏：暂停该区域（G1.7）。
    case closeSection(UUID)
    /// 关闭整个面板：暂停其中所有区域（G1.7）。
    case closeAll
    /// 在面板内移动一栏，`by` 为在 `PanelGroup.sections` 中的偏移（G4.3）。
    case moveSection(UUID, by: Int)
    case moveToNewPanel(UUID)
    case moveRegion(UUID, to: UUID)
    /// 把整个面板合并到另一个面板（G4.4）。
    case merge(into: UUID)
}

/// 一个面板窗口（panel-groups G1）：位置（贴边/悬浮/吸附）、调整大小、折叠细边、锁定、可见性，以及栏的比例和折叠。
/// 每栏的条目由 `SectionController` 管理。贴边位置由 `SessionCoordinator` 统一计算（G5）。
@MainActor
@Observable
final class PanelWindowController {
    private(set) var group: PanelGroup
    /// 与 `group.sections` 顺序一致，包含已暂停的区域。
    private(set) var sections: [SectionController] = []
    private(set) var isLocked = false
    /// 贴边时为外侧或内侧，悬浮时为 `nil`。
    private(set) var dockPlacement: DockLayout.Placement?
    /// 贴边时实际贴合的边。所选边外侧放不下时可能换到对边（R9.2）。
    private(set) var actualDockEdge: DockEdge?
    private(set) var isHoverExpanded = false
    /// 鼠标在面板上（离开后延迟隐藏，拖动中保持，panel-redesign P4.1）。
    private(set) var isHovering = false

    var id: UUID { group.id }

    /// 贴边为 HUD 玻璃，悬浮为字幕样式（P1.1）。拖动中位置不变，松开后才切换（P1.2）。
    var style: PanelStyle { PanelStyle(placement: group.placement) }

    /// 标题栏按钮、调整大小手柄、分隔条手柄是否显示（P4.1、P4.2）。
    var controlsVisible: Bool { isHovering && !isLocked }

    /// 面板第一栏的模式，决定折叠细边的颜色（P1.4）。
    var primaryMode: RegionMode { (visibleSections.first ?? sections.first)?.mode ?? .chat }

    /// 显示中的栏（未暂停、未关闭，G1.6）。
    var visibleSections: [SectionController] { sections.filter { !$0.isHidden } }
    var isMultiSection: Bool { visibleSections.count > 1 }

    /// 面板名称：区域名称用“ + ”连接。
    var displayName: String {
        let names = (visibleSections.isEmpty ? sections : visibleSections).map(\.regionName)
        return names.isEmpty ? "面板" : names.joined(separator: " + ")
    }

    /// 内侧贴边且折叠时只显示一条细边（R9.3）。
    var isCollapsedStrip: Bool {
        dockPlacement == .inside && group.collapsedStrip && !isHoverExpanded
    }

    /// 贴在顶部或底部时栏左右排列，其余情况上下排列（G1.2）。
    var isVerticalStack: Bool {
        guard group.placement.isDocked, let actualDockEdge else { return true }
        return !actualDockEdge.isHorizontal
    }

    /// 可见栏的布局参数。只有一栏时不折叠；所有栏都折叠时第一栏按展开处理（G3.5）。
    var sectionItems: [SectionLayout.Item] {
        let visible = visibleSections
        var items = visible.map { section in
            SectionLayout.Item(
                weight: sectionEntry(section.regionID)?.weight ?? 1,
                collapsed: visible.count > 1 && (sectionEntry(section.regionID)?.isCollapsed ?? false)
            )
        }
        if !items.isEmpty, items.allSatisfy(\.collapsed) { items[0].collapsed = false }
        return items
    }

    func sectionEntry(_ regionID: UUID) -> PanelSection? {
        group.sections.first { $0.regionID == regionID }
    }

    /// 栏所在的内容区（原点左上）。多栏时没有顶部拖动条，拖动栏标题移动面板（P4.4）。
    func contentRect(in size: CGSize) -> CGRect {
        CGRect(origin: .zero, size: size)
    }

    /// 各栏和分隔条的位置（原点左上，G2）。
    func sectionFrames(in size: CGSize) -> (sections: [CGRect], dividers: [CGRect]) {
        SectionLayout.frames(in: contentRect(in: size), items: sectionItems, vertical: isVerticalStack)
    }

    @ObservationIgnored var onGroupChange: ((PanelGroup) -> Void)?
    @ObservationIgnored var onCommand: ((PanelCommand) -> Void)?
    /// 请求重新计算所有面板的位置（G5）。
    @ObservationIgnored var onNeedsLayout: (() -> Void)?
    /// 同一目标窗口的其他面板，用于“移到”“合并到”菜单。
    @ObservationIgnored var otherPanels: () -> [PanelChoice] = { [] }

    @ObservationIgnored let panel = TranslationPanel()
    @ObservationIgnored private let snapPreview = SnapPreviewWindow()
    @ObservationIgnored private var targetFrame: CGRect
    @ObservationIgnored private var isTargetVisible = true
    @ObservationIgnored private(set) var isPanelShown = false
    @ObservationIgnored private var interaction: Interaction?
    @ObservationIgnored private var dividerDrag: DividerDrag?
    @ObservationIgnored private var collapseWork: DispatchWorkItem?
    @ObservationIgnored private var hoverWork: DispatchWorkItem?
    @ObservationIgnored private var isMouseInside = false

    private struct Interaction {
        var startMouse: CGPoint
        var startFrame: CGRect
        var resize: PanelResizeHandle?
        var snapCandidate: DockEdge?
    }

    private struct DividerDrag {
        let index: Int
        let startLengths: [CGFloat]
        let items: [SectionLayout.Item]
        let regionIDs: [UUID]
    }

    init(group: PanelGroup, targetFrame: CGRect) {
        self.group = group
        self.targetFrame = targetFrame
        let hostingView = PanelHostingView(rootView: PanelGroupView(window: self))
        hostingView.onMouseDown = { [weak self] in self?.onCommand?(.activate) }
        hostingView.onHoverChange = { [weak self] hovering in self?.setHovering(hovering) }
        hostingView.resizeEdges = { [weak self] point, size in self?.resizeEdges(at: point, in: size) }
        hostingView.onResizeBegin = { [weak self] edges in self?.beginResize(edges: edges) }
        hostingView.onResize = { [weak self] in self?.resize() }
        hostingView.onResizeEnd = { [weak self] in self?.endResize() }
        hostingView.dividerAt = { [weak self] point, size in self?.divider(at: point, in: size) }
        hostingView.dividerIsVertical = { [weak self] in self?.isVerticalStack ?? true }
        hostingView.onDividerBegin = { [weak self] index, size in self?.beginDividerDrag(index, size: size) }
        hostingView.onDividerDrag = { [weak self] delta in self?.dragDivider(by: delta) }
        hostingView.onDividerEnd = { [weak self] in self?.endDividerDrag() }
        panel.contentView = hostingView
    }

    // MARK: - 外部状态

    /// 由 `SessionCoordinator` 设置面板数据和栏，不触发 `onGroupChange`。
    func setGroup(_ group: PanelGroup, sections: [SectionController]) {
        self.group = group
        self.sections = sections
        panel.setAccessibilityLabel("\(displayName) 的译文面板")
        sectionsChanged()
    }

    /// 栏的暂停、关闭或名称变化后调用。
    func sectionsChanged() {
        refreshSectionStates()
        updateVisibility()
    }

    func tearDown() {
        collapseWork?.cancel()
        hoverWork?.cancel()
        snapPreview.orderOut(nil)
        panel.orderOut(nil)
        isPanelShown = false
    }

    func targetMoved(to frame: CGRect) {
        targetFrame = frame
    }

    func setTargetVisible(_ visible: Bool) {
        isTargetVisible = visible
        updateVisibility()
    }

    func setLocked(_ locked: Bool) {
        isLocked = locked
        panel.ignoresMouseEvents = locked // 锁定后鼠标穿透到下方窗口（R11.5）
    }

    private func updateVisibility() {
        let shouldShow = isTargetVisible && !visibleSections.isEmpty
        if shouldShow && !isPanelShown {
            isPanelShown = true
            layout()
            panel.orderFrontRegardless() // 不激活 TransPeek
        } else if !shouldShow && isPanelShown {
            isPanelShown = false
            panel.orderOut(nil)
            snapPreview.orderOut(nil)
            layout() // 同一条边上的其他面板重新分段（G5）
        }
    }

    /// 把实际折叠状态同步到各栏，用于统计折叠期间的新消息（G3.3）。
    private func refreshSectionStates() {
        for (section, item) in zip(visibleSections, sectionItems) {
            section.setCollapsed(item.collapsed)
        }
    }

    private func commitGroup(_ updated: PanelGroup) {
        guard updated != group else { return }
        group = updated
        refreshSectionStates()
        layout()
        onGroupChange?(updated)
    }

    // MARK: - 面板操作

    func closeSection(_ regionID: UUID) {
        onCommand?(.closeSection(regionID))
    }

    func closeAll() {
        onCommand?(.closeAll)
    }

    func setOpacity(_ opacity: Double) {
        var updated = group
        updated.opacity = min(max(opacity, PanelConfig.opacityRange.lowerBound), PanelConfig.opacityRange.upperBound)
        commitGroup(updated)
    }

    func dock(to edge: DockEdge) {
        var updated = group
        updated.placement = .docked(edge: edge, thickness: currentThickness(for: edge))
        commitGroup(updated)
    }

    func float() {
        let frameCG = ScreenGeometry.cg(fromCocoa: panel.frame)
        var size = frameCG.size
        size.width = max(size.width, 240)
        size.height = max(size.height, 160)
        var updated = group
        updated.placement = .floating(offset: CGPoint(x: targetFrame.width - size.width - 24, y: 48), size: size)
        commitGroup(updated)
    }

    func toggleCollapsedStrip() {
        isHoverExpanded = false
        var updated = group
        updated.collapsedStrip.toggle()
        commitGroup(updated)
    }

    // MARK: - 栏操作（G3、G4.3）

    func canCollapse(_ regionID: UUID) -> Bool {
        isMultiSection && PanelGroupOperations.canCollapse(regionID, visible: Set(visibleSections.map(\.regionID)), in: group)
    }

    func toggleSectionCollapsed(_ section: SectionController) {
        var groups = [group]
        let visible = Set(visibleSections.map(\.regionID))
        guard PanelGroupOperations.setCollapsed(section.regionID, !section.isCollapsed, visible: visible, in: &groups) else { return }
        // 实际显示为展开、但记录为折叠时（G3.5 的兜底），展开操作只需清除记录
        commitGroup(groups[0])
        onCommand?(.activate)
    }

    /// 与相邻的可见栏交换位置，`offset` 为 -1（上移）或 1（下移）。
    func neighborOffset(of regionID: UUID, direction: Int) -> Int? {
        let visible = visibleSections.map(\.regionID)
        guard let position = visible.firstIndex(of: regionID), visible.indices.contains(position + direction),
              let from = group.sections.firstIndex(where: { $0.regionID == regionID }),
              let to = group.sections.firstIndex(where: { $0.regionID == visible[position + direction] })
        else { return nil }
        return to - from
    }

    func moveSection(_ regionID: UUID, direction: Int) {
        guard let offset = neighborOffset(of: regionID, direction: direction) else { return }
        onCommand?(.moveSection(regionID, by: offset))
    }

    func moveToNewPanel(_ regionID: UUID) {
        onCommand?(.moveToNewPanel(regionID))
    }

    func moveRegion(_ regionID: UUID, to groupID: UUID) {
        onCommand?(.moveRegion(regionID, to: groupID))
    }

    func merge(into groupID: UUID) {
        onCommand?(.merge(into: groupID))
    }

    /// 鼠标进入立即显示控件，离开 0.4s 后隐藏（P4.1）；拖动、调整大小、拖动分隔条期间保持显示。
    /// 内侧折叠时，鼠标进入展开，离开 1s 后折叠（R9.3）。
    func setHovering(_ hovering: Bool) {
        isMouseInside = hovering
        hoverWork?.cancel()
        if hovering {
            if !isHovering { isHovering = true }
        } else {
            scheduleHoverEnd()
        }
        updateStripExpansion(hovering)
    }

    private var isInteracting: Bool { interaction != nil || dividerDrag != nil }

    private func scheduleHoverEnd() {
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isMouseInside, !self.isInteracting else { return }
                self.isHovering = false
                self.sections.forEach { $0.hideTextTools() }
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// 拖动结束后，鼠标已经不在面板上时隐藏控件。
    private func interactionEnded() {
        isMouseInside = panel.frame.contains(NSEvent.mouseLocation)
        if !isMouseInside { scheduleHoverEnd() }
    }

    private func updateStripExpansion(_ hovering: Bool) {
        guard dockPlacement == .inside, group.collapsedStrip else { return }
        collapseWork?.cancel()
        if hovering {
            if !isHoverExpanded {
                isHoverExpanded = true
                layout()
            }
        } else {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.interaction == nil, self.dividerDrag == nil else { return }
                    self.isHoverExpanded = false
                    self.layout()
                }
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        }
    }

    private func currentThickness(for edge: DockEdge) -> Double {
        if case let .docked(currentEdge, thickness) = group.placement, currentEdge.isHorizontal == edge.isHorizontal {
            return thickness
        }
        let size = panel.frame.size
        let value = edge.isHorizontal ? size.height : size.width
        return value >= 80 ? value : (edge.isHorizontal ? 140 : PanelConfig.defaultThickness)
    }

    // MARK: - 布局

    /// 请求重新布局。贴边面板的位置由 `SessionCoordinator.layoutAllPanels()` 统一计算（G5）。
    func layout() {
        if let onNeedsLayout {
            onNeedsLayout()
        } else {
            applyLayout(nil)
        }
    }

    /// 参与同一条边分段的请求。隐藏或悬浮的面板不参与（G5）。
    var dockRequest: DockLayoutCalculator.GroupRequest? {
        guard isPanelShown, case let .docked(edge, thickness) = group.placement else { return nil }
        return DockLayoutCalculator.GroupRequest(id: group.id, edge: edge, thickness: thickness, collapsed: group.collapsedStrip && !isHoverExpanded)
    }

    /// 应用布局结果。`dock` 为空时（悬浮，或没有统一计算的结果）自行计算。拖动中不移动面板。
    func applyLayout(_ dock: DockLayout?) {
        guard isPanelShown else { return }
        if let interaction, interaction.resize == nil { return }
        let frameCG: CGRect
        switch group.placement {
        case let .docked(edge, thickness):
            let result = dock ?? DockLayoutCalculator.layout(
                window: targetFrame, edge: edge, thickness: thickness,
                visibleFrame: ScreenGeometry.visibleFrameCG(for: targetFrame),
                collapsed: group.collapsedStrip && !isHoverExpanded
            )
            if dockPlacement != result.placement { dockPlacement = result.placement }
            if actualDockEdge != result.edge { actualDockEdge = result.edge }
            frameCG = result.frame
        case let .floating(offset, size):
            if dockPlacement != nil { dockPlacement = nil }
            if actualDockEdge != nil { actualDockEdge = nil }
            frameCG = CGRect(x: targetFrame.minX + offset.x, y: targetFrame.minY + offset.y, width: size.width, height: size.height)
        }
        let frame = ScreenGeometry.cocoa(fromCG: frameCG)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
        // 字幕样式几乎透明，窗口阴影会在游戏画面上留下灰边（design.md「背景」）
        let wantsShadow = style == .hud
        if panel.hasShadow != wantsShadow {
            panel.hasShadow = wantsShadow
            panel.invalidateShadow()
        }
    }

    // MARK: - 拖动与吸附（R10.1、R10.3、R10.4）

    func beginDrag() {
        interaction = Interaction(startMouse: NSEvent.mouseLocation, startFrame: panel.frame)
        onCommand?(.activate)
    }

    func drag() {
        guard var interaction, interaction.resize == nil else { return }
        let mouse = NSEvent.mouseLocation
        let origin = CGPoint(
            x: interaction.startFrame.minX + mouse.x - interaction.startMouse.x,
            y: interaction.startFrame.minY + mouse.y - interaction.startMouse.y
        )
        panel.setFrameOrigin(origin)

        let panelCG = ScreenGeometry.cg(fromCocoa: panel.frame)
        let candidate = SnapDetector.candidate(panel: panelCG, window: targetFrame)
        interaction.snapCandidate = candidate
        self.interaction = interaction
        if let candidate {
            let preview = DockLayoutCalculator.layout(
                window: targetFrame, edge: candidate, thickness: currentThickness(for: candidate),
                visibleFrame: ScreenGeometry.visibleFrameCG(for: targetFrame), collapsed: false
            )
            snapPreview.setFrame(ScreenGeometry.cocoa(fromCG: preview.frame), display: true)
            snapPreview.orderFrontRegardless()
        } else {
            snapPreview.orderOut(nil)
        }
    }

    func endDrag() {
        guard let interaction, interaction.resize == nil else { return }
        self.interaction = nil
        snapPreview.orderOut(nil)
        let panelCG = ScreenGeometry.cg(fromCocoa: panel.frame)
        var updated = group

        if let edge = interaction.snapCandidate {
            updated.placement = .docked(edge: edge, thickness: currentThickness(for: edge))
        } else if group.placement.isDocked,
                  !SnapDetector.isDetached(panel: panelCG, dockedFrame: ScreenGeometry.cg(fromCocoa: interaction.startFrame)) {
            // 贴边面板只是轻微拖动，回到原位
        } else {
            updated.placement = .floating(
                offset: CGPoint(x: panelCG.minX - targetFrame.minX, y: panelCG.minY - targetFrame.minY),
                size: panelCG.size
            )
        }
        if updated == group {
            layout()
        } else {
            commitGroup(updated)
        }
        interactionEnded()
    }

    // MARK: - 调整大小

    /// 面板内某个点（原点左上）可以拖动的边（R9.1、R10.1）。
    func resizeEdges(at point: CGPoint, in size: CGSize) -> Set<DockEdge>? {
        guard !isLocked, !isCollapsedStrip, interaction == nil || interaction?.resize != nil else { return nil }
        switch group.placement {
        case .floating:
            return PanelResizeZones.edges(at: point, in: size, allowedEdges: Set(DockEdge.allCases), allowsCorners: true)
        case .docked:
            guard let side = thicknessHandleSide else { return nil }
            return PanelResizeZones.edges(at: point, in: size, allowedEdges: [side], allowsCorners: false)
        }
    }

    func beginResize(edges: Set<DockEdge>) {
        switch group.placement {
        case .floating: beginResize(.floating(edges))
        case .docked: if let side = edges.first { beginResize(.thickness(side)) }
        }
    }

    func beginResize(_ handle: PanelResizeHandle) {
        interaction = Interaction(startMouse: NSEvent.mouseLocation, startFrame: panel.frame, resize: handle)
        onCommand?(.activate)
    }

    func resize() {
        guard let interaction, let handle = interaction.resize else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - interaction.startMouse.x
        let dy = mouse.y - interaction.startMouse.y
        let start = interaction.startFrame

        switch (handle, group.placement) {
        case let (.floating(edges), .floating):
            // Cocoa 坐标：原点在左下，y 向上
            var frame = start
            let minWidth: CGFloat = 160
            let minHeight: CGFloat = isMultiSection ? SectionLayout.minExpanded * 2 + SectionLayout.dividerSize : 48
            if edges.contains(.right) { frame.size.width = max(minWidth, start.width + dx) }
            if edges.contains(.left) {
                frame.size.width = max(minWidth, start.width - dx)
                frame.origin.x = start.maxX - frame.width
            }
            if edges.contains(.top) { frame.size.height = max(minHeight, start.height + dy) }
            if edges.contains(.bottom) {
                frame.size.height = max(minHeight, start.height - dy)
                frame.origin.y = start.maxY - frame.height
            }
            let frameCG = ScreenGeometry.cg(fromCocoa: frame)
            group.placement = .floating(
                offset: CGPoint(x: frameCG.minX - targetFrame.minX, y: frameCG.minY - targetFrame.minY),
                size: frameCG.size
            )
        case let (.thickness(side), .docked(edge, _)):
            let delta: CGFloat = switch side {
            case .right: dx
            case .left: -dx
            case .top: dy
            case .bottom: -dy
            }
            // 厚度以实际显示的尺寸为基准（外侧空间不足时面板可能比设定值窄）
            let base = side.isHorizontal ? start.height : start.width
            group.placement = .docked(edge: edge, thickness: min(max(base + delta, DockLayoutCalculator.minThickness), 2000))
        default:
            return
        }
        layout()
    }

    func endResize() {
        guard interaction?.resize != nil else { return }
        interaction = nil
        onGroupChange?(group)
        interactionEnded()
    }

    /// 贴边模式下用于调整厚度的面板边：外侧贴边时是远离窗口的一边，内侧贴边时是朝向窗口中心的一边。
    var thicknessHandleSide: DockEdge? {
        guard case .docked = group.placement, let edge = actualDockEdge, !isCollapsedStrip else { return nil }
        return dockPlacement == .outside ? edge : edge.opposite
    }

    // MARK: - 分隔条（G2.1）

    /// 某个点（原点左上）所在的可拖动分隔条。
    func divider(at point: CGPoint, in size: CGSize) -> Int? {
        guard !isLocked, !isCollapsedStrip, isMultiSection, interaction == nil else { return nil }
        let items = sectionItems
        let vertical = isVerticalStack
        for (index, rect) in sectionFrames(in: size).dividers.enumerated() where SectionLayout.isDraggable(divider: index, items: items) {
            // 命中区域比分隔条略宽，便于拖动
            if rect.insetBy(dx: vertical ? 0 : -2, dy: vertical ? -2 : 0).contains(point) { return index }
        }
        return nil
    }

    func beginDividerDrag(_ index: Int, size: CGSize) {
        let items = sectionItems
        let rect = contentRect(in: size)
        dividerDrag = DividerDrag(
            index: index,
            startLengths: SectionLayout.lengths(total: isVerticalStack ? rect.height : rect.width, items: items),
            items: items,
            regionIDs: visibleSections.map(\.regionID)
        )
        onCommand?(.activate)
    }

    /// `delta`：分隔条移动的距离，向下（或向右）为正。
    func dragDivider(by delta: CGFloat) {
        guard let drag = dividerDrag else { return }
        let weights = SectionLayout.dragDivider(drag.index, delta: delta, startLengths: drag.startLengths, items: drag.items)
        var updated = group
        for (regionID, weight) in zip(drag.regionIDs, weights) {
            if let index = updated.sections.firstIndex(where: { $0.regionID == regionID }) {
                updated.sections[index].weight = max(weight, 0.05)
            }
        }
        if updated != group { group = updated }
    }

    func endDividerDrag() {
        guard dividerDrag != nil else { return }
        dividerDrag = nil
        onGroupChange?(group)
        interactionEnded()
    }

    #if DEBUG
    /// Debug 快照工具：模拟鼠标悬停。
    func setHoveringForSnapshot(_ hovering: Bool) {
        isMouseInside = hovering
        isHovering = hovering
    }
    #endif
}
