import AppKit
import Observation
import OSLog
import TransPeekKit

/// 新区域或移动的区域放到哪个面板（panel-groups G4.1）。
enum PanelDestination: Hashable {
    case newPanel
    case group(UUID)

    var groupID: UUID? {
        if case let .group(id) = self { return id }
        return nil
    }
}

/// 持有目标窗口与区域、面板的映射关系，处理快捷键和菜单命令（design.md「SessionCoordinator」）。
/// 按区域保存流水线和栏（`SectionController`），按面板保存窗口（`PanelWindowController`，panel-groups）。
@MainActor
@Observable
final class SessionCoordinator {
    private struct RegionSession {
        let pipeline: RegionPipeline
        let section: SectionController
    }

    private(set) var target: TrackedWindow?
    private(set) var isTargetClosed = false
    /// 当前目标应用预设中的区域。
    private(set) var regions: [Region] = []
    /// 面板，每个区域恰好属于一个面板（G1）。
    private(set) var panelGroups: [PanelGroup] = []
    /// 新框选的区域默认加入的面板（G4.2）。
    private(set) var currentGroupID: UUID?
    private(set) var allLocked = false
    /// 预设文件损坏，已备份并使用空预设。
    private(set) var presetRecovered = false
    /// 最近一次需要告诉用户的问题，显示在菜单栏菜单中。
    var lastError: String?

    var allPaused: Bool { !regions.isEmpty && regions.allSatisfy(\.isPaused) }
    var hasOnceRegions: Bool { regions.contains { $0.mode == .once } }

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let tracker = PollingWindowTracker()
    @ObservationIgnored private let capture = CaptureService()
    @ObservationIgnored private let selector = RegionSelector()
    @ObservationIgnored private let logger = Logger(subsystem: AppIdentity.subsystem, category: "session")
    @ObservationIgnored private var sessions: [UUID: RegionSession] = [:]
    @ObservationIgnored private var windows: [UUID: PanelWindowController] = [:]
    @ObservationIgnored private var frameTask: Task<Void, Never>?
    @ObservationIgnored private var isStartingCapture = false
    @ObservationIgnored private var needsCaptureRebuild = false
    @ObservationIgnored private var streamRetries = 0
    @ObservationIgnored private var lastSettings: AppSettings
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?
    @ObservationIgnored private var profilesObserver: NSObjectProtocol?

    /// 需要显示权限引导时调用。
    @ObservationIgnored var onPermissionRequired: (() -> Void)?
    /// 面板中“未配置翻译服务”的提示被点击时调用，打开设置的翻译服务页（S1.5）。
    @ObservationIgnored var onOpenTranslationSettings: (() -> Void)?

    init(services: AppServices) {
        self.services = services
        lastSettings = services.settings.settings
        tracker.onEvent = { [weak self] windowID, event in
            self?.handleWindowEvent(windowID, event)
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: SettingsStore.didChangeNotification, object: services.settings, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        // 翻译配置变化后，区域可能从 Google 换成 LLM（或相反），更新智能整理是否生效（ocr-cleanup C2.1）
        profilesObserver = NotificationCenter.default.addObserver(
            forName: TranslationProfileStore.didChangeNotification, object: services.profiles, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPipelineConfigurations() }
        }
    }

    private var settings: AppSettings { services.settings.settings }

    // MARK: - 目标窗口（R3）

    func selectTarget(_ window: TrackedWindow) async {
        endSession()
        var window = window
        if let snapshot = PollingWindowTracker.snapshot(window.windowID) {
            window.frame = snapshot.frame
            window.isOnScreen = snapshot.isOnScreen
        }
        target = window
        isTargetClosed = false
        tracker.startTracking(window)

        // 自动加载该应用的预设（R3.3）。旧预设在解码时迁移为每个区域一个面板（G6）
        let result = await services.presetStore.load(bundleID: window.bundleID)
        guard target?.windowID == window.windowID else { return }
        presetRecovered = result.recoveredFromCorruption
        regions = result.preset.regions
        panelGroups = result.preset.panelGroups
        currentGroupID = result.preset.currentGroupID
        for region in regions { createSession(for: region) }
        syncPanels()
        logger.info("Target selected, \(self.regions.count, privacy: .public) regions in \(self.panelGroups.count, privacy: .public) panels loaded from preset")
        await rebuildCapture()
    }

    func endSession() {
        stopCapture()
        if let target { tracker.stopTracking(target.windowID) }
        windows.values.forEach { $0.tearDown() }
        windows = [:]
        sessions = [:]
        regions = []
        panelGroups = []
        currentGroupID = nil
        target = nil
        isTargetClosed = false
        presetRecovered = false
    }

    private func handleWindowEvent(_ windowID: CGWindowID, _ event: WindowEvent) {
        guard var target, target.windowID == windowID else { return }
        switch event {
        case let .moved(frame):
            let resized = frame.size != target.frame.size
            target.frame = frame
            self.target = target
            windows.values.forEach { $0.targetMoved(to: frame) }
            layoutAllPanels()
            if resized, capture.activeWindowIDs.contains(windowID) {
                capture.updateStream(windowID, frame: frame, fps: settings.sampleFPS)
            }
        case let .visibilityChanged(visible):
            // 最小化或切换到其他桌面时暂停识别并隐藏面板，恢复后自动继续（R3.5、R12.3）
            target.isOnScreen = visible
            self.target = target
            windows.values.forEach { $0.setTargetVisible(visible) }
            if visible {
                Task { await rebuildCapture() }
            } else {
                stopCapture()
            }
        case .closed:
            // 停止识别，保留面板历史直到用户关闭面板（R3.6）
            isTargetClosed = true
            stopCapture()
            sessions.values.forEach { $0.section.markTargetClosed() }
        }
    }

    // MARK: - 区域（R4）

    /// 框选新区域，或对已有区域重新框选（R4.1、R4.6）。没有目标窗口时使用前台窗口（R3.2）。
    func beginRegionSelection(reselecting regionID: UUID? = nil) async {
        services.permissions.refresh()
        guard services.permissions.screenCaptureGranted else {
            onPermissionRequired?()
            return
        }
        if target == nil || isTargetClosed {
            guard let front = WindowCatalog.frontmostWindow() else {
                lastError = "没有找到可以框选的窗口，请先切换到目标应用，或在菜单中选择目标窗口"
                return
            }
            await selectTarget(front)
        }
        guard let target, let snapshot = PollingWindowTracker.snapshot(target.windowID), snapshot.isOnScreen else {
            lastError = "目标窗口当前不可见，无法框选"
            return
        }
        lastError = nil
        selector.begin(targetFrame: snapshot.frame) { [weak self] rect in
            guard let self else { return }
            guard let rect else {
                self.reactivateTarget()
                return
            }
            if let regionID, var region = self.regions.first(where: { $0.id == regionID }) {
                region.rect = rect
                self.updateRegion(region)
                self.reactivateTarget()
            } else {
                self.presentNewRegionConfig(rect: rect)
            }
        }
    }

    /// 新面板使用设置中的默认样式（S5.2）。悬浮时放在目标窗口右上角内侧。
    private func newPanelConfig(settings: AppSettings) -> PanelConfig {
        var config = settings.newPanelConfig
        if case let .floating(_, size) = config.placement, let target {
            config.placement = .floating(offset: CGPoint(x: max(0, target.frame.width - size.width - 24), y: 48), size: size)
        }
        return config
    }

    /// 新面板（G4.2）：位置和不透明度使用设置中的默认值。
    private func makeNewGroup() -> PanelGroup {
        let config = newPanelConfig(settings: settings)
        return PanelGroup(placement: config.placement, opacity: config.opacity, collapsedStrip: config.collapsed, createdAt: Date())
    }

    private func presentNewRegionConfig(rect: CGRect) {
        let settings = self.settings
        let region = Region(
            name: "区域 \(regions.count + 1)",
            rect: rect,
            mode: .chat,
            sourceLanguage: settings.defaultSourceLanguage,
            targetLanguage: settings.defaultTargetLanguage,
            panel: newPanelConfig(settings: settings)
        )
        // “显示在”默认当前面板；当前窗口还没有面板时默认新面板（G4.1、G4.2）
        let choices = panelChoices()
        let destination: PanelDestination = currentGroupID.flatMap { id in
            choices.contains { $0.id == id } ? .group(id) : nil
        } ?? .newPanel
        let presenter = services.presenter
        presenter.show(id: "region-config", title: "新区域", size: CGSize(width: 400, height: 360), floating: true, resizable: false) {
            RegionConfigView(
                region: region,
                profiles: services.profiles.profiles,
                panelChoices: choices,
                currentGroupID: currentGroupID,
                destination: destination,
                onConfirm: { [weak self] configured, destination in
                    presenter.close("region-config")
                    self?.addRegion(configured, to: destination)
                    self?.reactivateTarget()
                },
                onCancel: { [weak self] in
                    presenter.close("region-config")
                    self?.reactivateTarget()
                }
            )
        }
    }

    /// 添加区域并放入指定面板（G4.1）。该面板成为当前面板（G4.2）。
    func addRegion(_ region: Region, to destination: PanelDestination) {
        guard target != nil else { return }
        regions.append(region)
        createSession(for: region)
        currentGroupID = PanelGroupOperations.add(region.id, mode: region.mode, to: destination.groupID, newGroup: makeNewGroup(), in: &panelGroups)
        syncPanels()
        persist()
        Task {
            await rebuildCapture()
            if region.mode == .once { await recognizeOnce(regionIDs: [region.id]) } // 框选后识别一次（R4.3）
        }
    }

    func updateRegion(_ region: Region) {
        guard let index = regions.firstIndex(where: { $0.id == region.id }) else { return }
        regions[index] = region
        if let session = sessions[region.id] {
            session.section.update(region: region)
            let configuration = pipelineConfiguration(for: region)
            Task { await session.pipeline.update(configuration) }
        }
        refreshWindows()
        persist()
        Task { await rebuildCapture() }
    }

    func deleteRegion(_ regionID: UUID) {
        regions.removeAll { $0.id == regionID }
        sessions.removeValue(forKey: regionID)
        PanelGroupOperations.remove(regionID, from: &panelGroups)
        syncPanels()
        persist()
        Task { await rebuildCapture() }
    }

    func setPaused(_ regionID: UUID, _ paused: Bool) {
        setPaused([regionID], paused)
    }

    private func setPaused(_ regionIDs: [UUID], _ paused: Bool) {
        for id in regionIDs {
            guard let index = regions.firstIndex(where: { $0.id == id }), regions[index].isPaused != paused else { continue }
            regions[index].isPaused = paused
            if let session = sessions[id] {
                session.section.update(region: regions[index])
                let configuration = pipelineConfiguration(for: regions[index])
                Task { await session.pipeline.update(configuration) }
            }
        }
        refreshWindows()
        persist()
        Task { await rebuildCapture() }
    }

    private func createSession(for region: Region) {
        let section = SectionController(region: region, historyLimit: settings.historyLimit)
        let pipeline = RegionPipeline(
            configuration: pipelineConfiguration(for: region),
            ocr: services.ocr,
            translator: services.translation,
            output: { [weak section] event in
                // 主队列按顺序投递，保证条目的追加先于更新
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { section?.apply(event) }
                }
            }
        )
        let regionID = region.id
        if isTargetClosed { section.markTargetClosed() }
        // 栏级设置（字号、显示原文）写回区域（G1.4）
        section.onConfigChange = { [weak self] config in
            guard let self, let index = self.regions.firstIndex(where: { $0.id == regionID }) else { return }
            self.regions[index].panel = config
            self.persist()
        }
        section.onOpenSettings = { [weak self] in self?.onOpenTranslationSettings?() }
        section.onRetry = { entry in
            Task { await pipeline.retry(entry) }
        }
        sessions[regionID] = RegionSession(pipeline: pipeline, section: section)

        // 预热该区域语言的识别模型；加载期间显示提示（R14.5）
        let warmUp = services.ocrWarmUp
        let languages = region.sourceLanguage.map { [$0.visionCode] }
        Task { [weak section] in
            if await !warmUp.isWarm(languages: languages) {
                section?.setPreparingOCR(true)
                await warmUp.warmUp(languages: languages)
            }
            section?.setPreparingOCR(false)
        }
    }

    private func pipelineConfiguration(for region: Region) -> PipelineConfiguration {
        PipelineConfiguration(
            region: region,
            appName: target?.appName ?? "",
            confidenceThreshold: settings.ocrConfidenceThreshold,
            debugLogging: settings.debugLogging,
            usesLLM: services.profiles.resolve(region.translationProfileID, defaultID: settings.defaultProfileID)?.llmConfig != nil
        )
    }

    private func refreshPipelineConfigurations() {
        for region in regions {
            guard let session = sessions[region.id] else { continue }
            let configuration = pipelineConfiguration(for: region)
            Task { await session.pipeline.update(configuration) }
        }
    }

    private func persist() {
        guard let target else { return }
        let preset = AppPreset(bundleID: target.bundleID, regions: regions, panelGroups: panelGroups, currentGroupID: currentGroupID, updatedAt: Date())
        let store = services.presetStore
        Task { await store.scheduleSave(preset) }
    }

    // MARK: - 面板（panel-groups）

    /// 当前目标窗口的面板，名称为其中区域名称的连接（G4.1、G4.6）。
    func panelChoices(excluding excluded: UUID? = nil) -> [PanelChoice] {
        panelGroups
            .filter { $0.id != excluded }
            .map { PanelChoice(id: $0.id, name: PanelGroupOperations.displayName(of: $0, regions: regions)) }
    }

    func groupID(containing regionID: UUID) -> UUID? {
        PanelGroupOperations.groupID(containing: regionID, in: panelGroups)
    }

    /// 把区域移到其他面板或新面板（G4.3、G4.5、G4.6）。栏级设置保存在区域中，随区域移动。
    func moveRegion(_ regionID: UUID, to destination: PanelDestination) {
        guard let region = regions.first(where: { $0.id == regionID }) else { return }
        if let groupID = destination.groupID, groupID == self.groupID(containing: regionID) { return }
        currentGroupID = PanelGroupOperations.add(regionID, mode: region.mode, to: destination.groupID, newGroup: makeNewGroup(), in: &panelGroups)
        syncPanels()
        persist()
    }

    private func handle(_ command: PanelCommand, from groupID: UUID) {
        switch command {
        case .activate:
            guard currentGroupID != groupID, panelGroups.contains(where: { $0.id == groupID }) else { return }
            currentGroupID = groupID
            persist()
        case let .closeSection(regionID):
            closeRegions([regionID])
        case .closeAll:
            closeRegions(panelGroups.first { $0.id == groupID }?.regionIDs ?? [])
        case let .moveSection(regionID, offset):
            PanelGroupOperations.moveSection(regionID, by: offset, in: &panelGroups)
            currentGroupID = groupID
            syncPanels()
            persist()
        case let .moveToNewPanel(regionID):
            moveRegion(regionID, to: .newPanel)
        case let .moveRegion(regionID, targetID):
            moveRegion(regionID, to: .group(targetID))
        case let .merge(targetID):
            PanelGroupOperations.merge(groupID, into: targetID, in: &panelGroups)
            currentGroupID = targetID
            syncPanels()
            persist()
        }
    }

    /// 关闭栏或面板等同于暂停区域（G1.7）。目标窗口已关闭时只隐藏，不改变区域的暂停状态（R3.6）。
    private func closeRegions(_ regionIDs: [UUID]) {
        if isTargetClosed {
            regionIDs.forEach { sessions[$0]?.section.dismiss() }
            refreshWindows()
        } else {
            setPaused(regionIDs, true)
        }
    }

    /// 面板的位置、不透明度、比例、折叠等变化写回预设（R4.7）。
    private func groupChanged(_ group: PanelGroup) {
        guard let index = panelGroups.firstIndex(where: { $0.id == group.id }) else { return }
        panelGroups[index] = group
        currentGroupID = group.id
        persist()
    }

    /// 按 `panelGroups` 创建、更新和删除面板窗口。
    private func syncPanels() {
        guard let target else { return }
        let ids = Set(panelGroups.map(\.id))
        for (id, window) in windows where !ids.contains(id) {
            window.tearDown()
            windows[id] = nil
        }
        for group in panelGroups {
            let window = windows[group.id] ?? makeWindow(for: group, target: target)
            window.setGroup(group, sections: group.regionIDs.compactMap { sessions[$0]?.section })
        }
        layoutAllPanels()
    }

    private func makeWindow(for group: PanelGroup, target: TrackedWindow) -> PanelWindowController {
        let window = PanelWindowController(group: group, targetFrame: target.frame)
        let groupID = group.id
        window.setLocked(allLocked)
        window.onNeedsLayout = { [weak self] in self?.layoutAllPanels() }
        window.onGroupChange = { [weak self] group in self?.groupChanged(group) }
        window.onCommand = { [weak self] command in self?.handle(command, from: groupID) }
        window.otherPanels = { [weak self] in self?.panelChoices(excluding: groupID) ?? [] }
        windows[groupID] = window
        window.setTargetVisible(target.isOnScreen)
        return window
    }

    /// 暂停、恢复、改名、关闭栏之后刷新面板的显示。
    private func refreshWindows() {
        windows.values.forEach { $0.sectionsChanged() }
    }

    /// 统一计算所有贴边面板的位置：同一条边上的多个面板平分长度，按创建顺序排列（G5）。
    func layoutAllPanels() {
        guard let target else { return }
        let ordered = panelGroups.compactMap { windows[$0.id] }.sorted { $0.group.createdAt < $1.group.createdAt }
        let results = DockLayoutCalculator.layoutGroups(
            window: target.frame,
            requests: ordered.compactMap(\.dockRequest),
            visibleFrame: ScreenGeometry.visibleFrameCG(for: target.frame)
        )
        for window in ordered {
            window.applyLayout(results[window.id])
        }
    }

    // MARK: - 快捷键与菜单命令（R2.3）

    func handle(_ action: HotkeyAction) {
        switch action {
        case .selectRegion:
            guard !selector.isActive else { return }
            Task { await beginRegionSelection() }
        case .toggleLock:
            toggleLockAll()
        case .togglePause:
            togglePauseAll()
        case .rerunOnce:
            Task { await recognizeOnce() }
        }
    }

    func toggleLockAll() {
        allLocked.toggle()
        windows.values.forEach { $0.setLocked(allLocked) }
    }

    func togglePauseAll() {
        setPaused(regions.map(\.id), !allPaused)
    }

    /// 对单次区域重新识别（R2.3 ⌃⌥R）。`regionIDs` 为空时识别所有未暂停的单次区域。
    func recognizeOnce(regionIDs: [UUID]? = nil) async {
        guard let target, !isTargetClosed else { return }
        let ids = regionIDs ?? regions.filter { $0.mode == .once && !$0.isPaused }.map(\.id)
        guard !ids.isEmpty else {
            lastError = "当前没有单次区域"
            return
        }
        do {
            let image = try await capture.screenshot(target)
            for id in ids {
                await sessions[id]?.pipeline.recognizeNow(windowImage: image)
            }
            lastError = nil
        } catch {
            lastError = "截图失败：\(error.localizedDescription)"
            services.permissions.reportCaptureFailure()
        }
    }

    private func reactivateTarget() {
        guard let target else { return }
        NSRunningApplication(processIdentifier: target.pid)?.activate()
    }

    // MARK: - 截取（R5）

    private func rebuildCapture() async {
        if isStartingCapture {
            needsCaptureRebuild = true
            return
        }
        guard let target, !isTargetClosed, target.isOnScreen,
              regions.contains(where: { $0.mode.isContinuous && !$0.isPaused })
        else {
            stopCapture()
            return
        }
        guard !capture.activeWindowIDs.contains(target.windowID) else { return }

        isStartingCapture = true
        defer {
            isStartingCapture = false
            if needsCaptureRebuild {
                needsCaptureRebuild = false
                Task { await rebuildCapture() }
            }
        }
        do {
            let frames = try await capture.startStream(window: target, fps: settings.sampleFPS) { [weak self] error in
                self?.streamStopped(error)
            }
            frameTask?.cancel()
            frameTask = Task { [weak self] in
                for await frame in frames {
                    guard let self else { break }
                    await self.dispatch(frame)
                }
            }
            streamRetries = 0
            lastError = nil
        } catch {
            logger.error("Failed to start capture: \(error.localizedDescription, privacy: .public)")
            lastError = "无法截取窗口：\(error.localizedDescription)"
            services.permissions.reportCaptureFailure()
        }
    }

    private func dispatch(_ frame: CapturedFrame) async {
        for region in regions where region.mode.isContinuous && !region.isPaused {
            await sessions[region.id]?.pipeline.submit(windowImage: frame.image, at: frame.time)
        }
    }

    private func stopCapture() {
        frameTask?.cancel()
        frameTask = nil
        capture.stopAll()
    }

    /// stream 意外停止：窗口已关闭则停止区域；仍存在则 1s 后重建，最多重试 3 次（design.md「错误处理」）。
    private func streamStopped(_ error: Error?) {
        logger.error("Capture stopped: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        frameTask?.cancel()
        frameTask = nil
        guard let target else { return }
        capture.stopStream(target.windowID)
        guard PollingWindowTracker.snapshot(target.windowID) != nil else {
            handleWindowEvent(target.windowID, .closed)
            return
        }
        guard streamRetries < 3 else {
            lastError = "截取多次中断，请重新选择目标窗口"
            return
        }
        streamRetries += 1
        Task {
            try? await Task.sleep(for: .seconds(1))
            await rebuildCapture()
        }
    }

    // MARK: - 设置变化（R13.2）

    private func settingsChanged() {
        let new = settings
        let old = lastSettings
        lastSettings = new
        for region in regions {
            guard let session = sessions[region.id] else { continue }
            session.section.setHistoryLimit(new.historyLimit)
            let configuration = pipelineConfiguration(for: region)
            Task { await session.pipeline.update(configuration) }
        }
        if new.sampleFPS != old.sampleFPS, let target, capture.activeWindowIDs.contains(target.windowID) {
            capture.updateStream(target.windowID, frame: target.frame, fps: new.sampleFPS)
        }
    }
}
