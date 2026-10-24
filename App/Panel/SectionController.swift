import AppKit
import Observation
import TransPeekKit

/// 面板中的一栏，对应一个区域（panel-groups G1.4）。负责条目、未读数、自动滚动和栏级设置（字号、显示原文）。
/// 面板窗口的位置和大小由 `PanelWindowController` 管理。
@MainActor
@Observable
final class SectionController {
    let regionID: UUID
    private(set) var regionName: String
    private(set) var mode: RegionMode
    /// 只使用其中的栏级字段 `fontSize`、`showsOriginal`；面板级字段由所在面板管理（G1.3）。
    private(set) var config: PanelConfig
    private(set) var history: PanelHistory
    private(set) var isPaused = false
    /// 目标窗口已关闭后，用户关闭了这一栏：只隐藏，不暂停区域（R3.6）。
    private(set) var isDismissed = false
    private(set) var isTargetClosed = false
    /// 文字识别模型正在加载（首次运行约需半分钟，R14.5）。
    private(set) var isPreparingOCR = false
    /// 不在底部时累计的新消息数（R11.3）。
    private(set) var unreadCount = 0
    /// 有新条目时递增，视图据此自动滚动（R11.2）。
    private(set) var appendCounter = 0
    /// 最近一次“未配置翻译服务”之类的提示。
    private(set) var unavailableReason: String?
    /// 实际显示为折叠（由面板根据 G3.5 计算后设置）。
    private(set) var isCollapsed = false
    /// 折叠期间新增的消息数，显示在小标题上（G3.3）。
    private(set) var collapsedUnread = 0
    /// “Aa”工具条是否展开（panel-redesign P4.3），不保存。
    private(set) var isShowingTextTools = false
    /// HUD 样式中“之前的对话”是否展开（P2.4），不保存。
    private(set) var isDialogHistoryExpanded = false

    /// 面板中显示的条目：名字行作为说话人，标记最新一条（P5）。
    var displayItems: [DisplayItem] { history.displayItems() }

    func toggleTextTools() {
        isShowingTextTools.toggle()
    }

    func hideTextTools() {
        if isShowingTextTools { isShowingTextTools = false }
    }

    func toggleDialogHistory() {
        isDialogHistoryExpanded.toggle()
    }

    /// 暂停或被关闭的栏不显示（G1.6）。
    var isHidden: Bool { isPaused || isDismissed }

    private(set) var isAtBottom = true {
        didSet { if isAtBottom { unreadCount = 0 } }
    }
    @ObservationIgnored private var lastAutoScroll = Date.distantPast

    /// 栏级设置变化（字号、显示原文），写回区域。
    @ObservationIgnored var onConfigChange: ((PanelConfig) -> Void)?
    @ObservationIgnored var onRetry: ((Entry) -> Void)?
    /// 点击“未配置翻译服务”的提示时打开设置（S1.5）。
    @ObservationIgnored var onOpenSettings: (() -> Void)?

    init(region: Region, historyLimit: Int) {
        regionID = region.id
        regionName = region.name
        mode = region.mode
        config = region.panel
        isPaused = region.isPaused
        history = PanelHistory(limit: historyLimit)
    }

    // MARK: - 滚动

    /// 视图自动滚动到底部后调用。
    func didScrollToBottom() {
        lastAutoScroll = Date()
        isAtBottom = true
    }

    /// 底部标记视图出现/消失。新条目把标记挤出视野后、自动滚动完成前会短暂“消失”，这段时间内忽略。
    /// 折叠时列表被移除，也不改变是否在底部。
    func bottomMarkerVisible(_ visible: Bool) {
        guard !isCollapsed else { return }
        if visible {
            isAtBottom = true
        } else if Date().timeIntervalSince(lastAutoScroll) > 0.5 {
            isAtBottom = false
        }
    }

    // MARK: - 状态

    func apply(_ event: PipelineEvent) {
        let added = history.apply(event)
        switch event {
        case .append, .replaceAll, .dialog:
            // 对话模式每段新文本算一条（G3.3）
            let newCount = if case .dialog = event { 1 } else { added }
            if isCollapsed, newCount > 0 { collapsedUnread += newCount }
            if isAtBottom || mode != .chat {
                appendCounter += 1
            } else {
                unreadCount += added
            }
        case .update(_, .hidden):
            // 被判为界面文字的条目已删除，不再计入未读（ocr-cleanup C3.2）
            if added < 0 {
                if !isAtBottom { unreadCount = max(0, unreadCount + added) }
                if isCollapsed { collapsedUnread = max(0, collapsedUnread + added) }
            }
        case let .update(_, state):
            if case let .unavailable(reason) = state { unavailableReason = reason } else if state.translatedText != nil { unavailableReason = nil }
        }
    }

    func update(region: Region) {
        regionName = region.name
        mode = region.mode
        isPaused = region.isPaused
        if !region.isPaused { isDismissed = false }
        config = region.panel
    }

    func setCollapsed(_ collapsed: Bool) {
        guard collapsed != isCollapsed else { return }
        isCollapsed = collapsed
        collapsedUnread = 0
    }

    func setHistoryLimit(_ limit: Int) {
        history.limit = limit
    }

    func markTargetClosed() {
        isTargetClosed = true
    }

    func dismiss() {
        isDismissed = true
    }

    func setPreparingOCR(_ preparing: Bool) {
        isPreparingOCR = preparing
    }

    // MARK: - 操作

    func retry(_ entry: Entry) {
        onRetry?(entry)
    }

    func clearHistory() {
        history.clear()
        unreadCount = 0
        collapsedUnread = 0
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyAll() {
        copy(history.plainText(includeOriginal: config.showsOriginal))
    }

    func toggleOriginal() {
        mutateConfig { $0.showsOriginal.toggle() }
    }

    func adjustFontSize(by delta: Double) {
        mutateConfig { $0 = PanelConfig(placement: $0.placement, opacity: $0.opacity, fontSize: $0.fontSize + delta, showsOriginal: $0.showsOriginal, collapsed: $0.collapsed) }
    }

    private func mutateConfig(_ change: (inout PanelConfig) -> Void) {
        var updated = config
        change(&updated)
        guard updated != config else { return }
        config = updated
        onConfigChange?(updated)
    }
}
