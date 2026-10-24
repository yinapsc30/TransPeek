import CoreGraphics
import Foundation
import OSLog

/// 流水线发给面板的事件。
public enum PipelineEvent: Sendable, Equatable {
    /// 聊天模式的新行（可能以遗漏标记开头）。
    case append([Entry])
    /// 单次模式：用本次识别结果替换面板内容。
    case replaceAll([Entry])
    /// 对话模式：新的一段文本。
    case dialog(Entry)
    /// 条目的翻译完成。
    case update(entryID: UUID, state: TranslationState)
}

/// 流水线配置，区域或设置修改后通过 `update(_:)` 更新。
public struct PipelineConfiguration: Sendable, Equatable {
    public var region: Region
    public var appName: String
    public var confidenceThreshold: Double
    public var debugLogging: Bool
    public var changeThreshold: Double = 2.0
    public var stableDuration: TimeInterval = 0.25
    public var maxWait: TimeInterval = 1.0
    /// 保留的上下文条数上限（LLM 再按配置截断）。
    public var contextLimit: Int = LLMConfig.contextCountRange.upperBound
    /// 区域使用的翻译配置是否为 LLM，由 App 层根据翻译配置计算（ocr-cleanup C2.1）。
    public var usesLLM: Bool

    public init(region: Region, appName: String, confidenceThreshold: Double = 0.3, debugLogging: Bool = false, usesLLM: Bool = false) {
        self.region = region
        self.appName = appName
        self.confidenceThreshold = confidenceThreshold
        self.debugLogging = debugLogging
        self.usesLLM = usesLLM
    }

    /// 智能整理是否生效：区域开启、翻译配置是 LLM、不是对话模式（C2.1、C2.5）。
    public var classifiesLines: Bool {
        region.smartCleanup && usesLLM && region.mode != .dialog
    }
}

/// 单个区域的处理流水线：裁剪 → 变化检测 → 稳定判定 → OCR → 行组装 → 按模式处理 → 翻译（design.md「RegionPipeline」）。
/// 每个区域一个 actor，区域内串行，区域之间并行。
public actor RegionPipeline {
    public typealias Output = @Sendable (PipelineEvent) -> Void

    private var configuration: PipelineConfiguration
    private let ocr: any OCREngine
    private let translator: any TranslationServicing
    private let output: Output
    private let logger = Logger(subsystem: AppIdentity.subsystem, category: "pipeline")
    private let signposter = OSSignposter(subsystem: AppIdentity.subsystem, category: "pipeline")

    private var detector: ChangeDetector
    private var gate: StabilityGate
    private var assembler: LineAssembler
    private var rules: IgnoreRules
    private let differ = LineDiffer()
    private let noiseFilter = NoiseFilter()

    /// 上次识别时的画面，变化检测的基准。
    private var baseline: GrayThumbnail?
    private var previousFrame: GrayThumbnail?
    /// 聊天模式上一次的识别结果。
    private var previousLines: [String] = []
    /// 对话模式当前显示的文本。
    private var currentDialog: String?
    private var recentContext: [ContextPair] = []

    private var isProcessing = false
    /// OCR 进行中时只保留最新一帧（R5.5）。
    private var pending: (image: CGImage, thumbnail: GrayThumbnail?)?
    private var processingTask: Task<Void, Never>?
    private var translationTasks: [UUID: Task<Void, Never>] = [:]
    /// OCR 调用次数，供测试和调试使用。
    public private(set) var recognitionCount = 0

    public init(configuration: PipelineConfiguration, ocr: any OCREngine, translator: any TranslationServicing, output: @escaping Output) {
        self.configuration = configuration
        self.ocr = ocr
        self.translator = translator
        self.output = output
        self.detector = ChangeDetector(threshold: configuration.changeThreshold)
        self.gate = StabilityGate(stableDuration: configuration.stableDuration, maxWait: configuration.maxWait)
        self.assembler = LineAssembler(confidenceThreshold: configuration.confidenceThreshold)
        self.rules = IgnoreRules(patterns: configuration.region.ignorePatterns)
    }

    public var region: Region { configuration.region }

    public func update(_ newConfiguration: PipelineConfiguration) {
        let old = configuration
        configuration = newConfiguration
        detector = ChangeDetector(threshold: newConfiguration.changeThreshold)
        assembler = LineAssembler(confidenceThreshold: newConfiguration.confidenceThreshold)
        rules = IgnoreRules(patterns: newConfiguration.region.ignorePatterns)
        if old.region.rect != newConfiguration.region.rect || old.region.mode != newConfiguration.region.mode {
            resetRecognitionState()
        } else if old.region.ignorePatterns != newConfiguration.region.ignorePatterns {
            baseline = nil // 规则变化后重新识别一次
        }
    }

    /// 清空识别状态（重新框选、切换模式后调用），下一帧会重新识别。
    public func resetRecognitionState() {
        baseline = nil
        previousFrame = nil
        previousLines = []
        currentDialog = nil
        gate.reset()
        pending = nil
    }

    /// 持续监听模式的新帧（整个窗口的画面）。`time` 为单调递增的秒数。
    public func submit(windowImage: CGImage, at time: TimeInterval) {
        guard configuration.region.mode.isContinuous, !configuration.region.isPaused else { return }
        guard let cropped = crop(windowImage) else { return }
        let thumbnail = GrayThumbnail(image: cropped)
        guard let thumbnail else { return }

        let changed = detector.isChanged(from: baseline, to: thumbnail)
        let moved = detector.isChanged(from: previousFrame, to: thumbnail)
        previousFrame = thumbnail

        if case .fire = gate.feed(changedFromBaseline: changed, movedSincePreviousFrame: moved, now: time) {
            enqueue(cropped, thumbnail: thumbnail)
        }
    }

    /// 立即识别一次，不经过变化检测（单次模式和手动重新识别，R4.3、R2.3）。
    public func recognizeNow(windowImage: CGImage) {
        guard let cropped = crop(windowImage) else { return }
        enqueue(cropped, thumbnail: GrayThumbnail(image: cropped))
    }

    /// 手动重试失败的条目（R8.6）。
    public func retry(_ entry: Entry) {
        guard entry.kind != .gapMarker, !entry.original.isEmpty else { return }
        output(.update(entryID: entry.id, state: .pending))
        startTranslation([entry])
    }

    /// 等待所有进行中的 OCR 和翻译完成（测试用）。
    public func waitUntilIdle() async {
        while true {
            if let processingTask {
                await processingTask.value
                continue
            }
            if let task = translationTasks.values.first {
                await task.value
                continue
            }
            return
        }
    }

    // MARK: - 内部流程

    private func crop(_ windowImage: CGImage) -> CGImage? {
        let size = CGSize(width: windowImage.width, height: windowImage.height)
        let rect = configuration.region.absoluteRect(in: size)
            .intersection(CGRect(origin: .zero, size: size))
        guard rect.width >= 4, rect.height >= 4 else { return nil }
        return windowImage.cropping(to: rect) // CGImage 的裁剪坐标原点在左上角
    }

    private func enqueue(_ image: CGImage, thumbnail: GrayThumbnail?) {
        if isProcessing {
            pending = (image, thumbnail)
            return
        }
        isProcessing = true
        processingTask = Task { await self.processLoop(first: (image, thumbnail)) }
    }

    private func processLoop(first: (image: CGImage, thumbnail: GrayThumbnail?)) async {
        var next: (image: CGImage, thumbnail: GrayThumbnail?)? = first
        while let item = next {
            await process(item.image, thumbnail: item.thumbnail)
            next = pending
            pending = nil
        }
        isProcessing = false
        processingTask = nil
    }

    private func process(_ image: CGImage, thumbnail: GrayThumbnail?) async {
        if let thumbnail { baseline = thumbnail }
        recognitionCount += 1
        let region = configuration.region
        let languages = region.sourceLanguage.map { [$0.visionCode] }

        let state = signposter.beginInterval("OCR")
        let fragments: [OCRFragment]
        do {
            fragments = try await ocr.recognize(image, languages: languages)
        } catch {
            signposter.endInterval("OCR", state)
            logger.error("OCR failed: \(error.localizedDescription, privacy: .public)")
            return // 跳过本帧，不影响下一帧
        }
        signposter.endInterval("OCR", state)

        var assembled = assembler.assemble(fragments, ignoring: rules)
        if region.mode == .chat {
            // 聊天滚动时，区域上下边缘的行可能只露出半截，识别结果残缺，下一次完整出现时会被当成新消息。
            // 贴着边缘的行先不处理，等它完整进入区域（R7.1）。
            assembled = Self.droppingClippedLines(assembled, imageHeight: image.height)
        }
        // 规则过滤（ocr-cleanup C1）：区域忽略规则已在 LineAssembler 中执行（C1.6）
        var lines: [ClassifiedLine] = assembled.map { ClassifiedLine(text: $0.text, role: .message) }
        if region.filtersNoise {
            let detectsMetadata = !configuration.classifiesLines // 智能整理生效时名字行交给模型判断（C1.4）
            lines = assembled.compactMap { line in
                noiseFilter.classify(line.text, detectsMetadata: detectsMetadata).map { ClassifiedLine(text: $0.text, role: $0.role) }
            }
        }
        if configuration.debugLogging {
            // 只有用户开启调试日志时才输出识别文本（R15.3）；notice 级别在 `log stream` 中默认可见
            let texts = lines.map(\.text)
            logger.notice("[\(region.name, privacy: .public)] OCR lines: \(texts, privacy: .public)")
        }
        handle(lines, mode: region.mode)
    }

    private struct ClassifiedLine {
        let text: String
        let role: LineRole
    }

    /// 名字/时间行直接显示，不翻译（C3.1）。
    private func makeEntries(_ lines: some Collection<ClassifiedLine>, regionID: UUID, timestamp: Date) -> [Entry] {
        lines.map { line in
            Entry(regionID: regionID, timestamp: timestamp, original: line.text, translation: line.role == .metadata ? .metadata : .pending)
        }
    }

    private func handle(_ classified: [ClassifiedLine], mode: RegionMode) {
        let regionID = configuration.region.id
        let now = Date()
        switch mode {
        case .chat:
            // 识别为空（如聊天框短暂隐藏）时保留上一次的结果，避免恢复后整屏重复
            guard !classified.isEmpty else { return }
            // 名字/时间行参与对齐（C1.5）
            let lines = classified.map(\.text)
            let diff = differ.diff(previous: previousLines, current: lines)
            previousLines = lines
            guard !diff.newLines.isEmpty else { return }
            var entries: [Entry] = []
            if diff.possibleGap { entries.append(.gapMarker(regionID: regionID, timestamp: now)) }
            // 新行总是 current 的末尾部分
            let lineEntries = makeEntries(classified.suffix(diff.newLines.count), regionID: regionID, timestamp: now)
            entries.append(contentsOf: lineEntries)
            output(.append(entries))
            startTranslation(lineEntries)

        case .dialog:
            // 对话模式整段翻译，名字/时间行不放进对话文本
            let text = classified.filter { $0.role == .message }.map(\.text).joined(separator: " ")
            guard DialogComparator.shouldReplace(current: currentDialog, with: text) else { return }
            currentDialog = text
            let entry = Entry(regionID: regionID, timestamp: now, original: text, kind: .dialogSnapshot)
            output(.dialog(entry))
            startTranslation([entry])

        case .once:
            let entries = makeEntries(classified, regionID: regionID, timestamp: now)
            output(.replaceAll(entries))
            startTranslation(entries)
        }
    }

    /// 去掉外接矩形贴着区域上边缘或下边缘（2 像素以内）的行。
    static func droppingClippedLines(_ lines: [OCRLine], imageHeight: Int) -> [OCRLine] {
        guard imageHeight > 0 else { return lines }
        let margin = 2.0 / CGFloat(imageHeight)
        return lines.filter { $0.box.minY > margin && $0.box.maxY < 1 - margin }
    }

    private func startTranslation(_ candidates: [Entry]) {
        // 名字/时间行不翻译（ocr-cleanup C3.1）
        var entries = candidates.filter { $0.translation != .metadata }
        guard !entries.isEmpty else { return }
        let region = configuration.region
        // 目标语言是中文时，已经是中文的行不翻译，直接显示原文（R8.9）
        if region.targetLanguage.isChinese {
            let (skipped, rest) = (entries.filter { TextScript.containsChinese($0.original) },
                                   entries.filter { !TextScript.containsChinese($0.original) })
            if !skipped.isEmpty {
                finishTranslation(id: UUID(), entries: skipped, results: skipped.map { .done($0.original) })
            }
            entries = rest
            guard !entries.isEmpty else { return }
        }
        let id = UUID()
        let options = TranslationOptions(
            source: region.sourceLanguage,
            target: region.targetLanguage,
            profileID: region.translationProfileID,
            context: recentContext,
            appName: configuration.appName,
            classifiesLines: configuration.classifiesLines
        )
        let translator = self.translator
        let signposter = self.signposter
        let batch = entries
        translationTasks[id] = Task {
            let state = signposter.beginInterval("Translate")
            let results = await translator.translate(batch.map(\.original), options: options)
            signposter.endInterval("Translate", state)
            self.finishTranslation(id: id, entries: batch, results: results)
        }
    }

    private func finishTranslation(id: UUID, entries: [Entry], results: [TranslationState]) {
        translationTasks.removeValue(forKey: id)
        for (entry, state) in zip(entries, results) {
            output(.update(entryID: entry.id, state: state))
            if let translated = state.translatedText, entry.kind == .line {
                recentContext.append(ContextPair(source: entry.original, translation: translated))
            }
        }
        if recentContext.count > configuration.contextLimit {
            recentContext.removeFirst(recentContext.count - configuration.contextLimit)
        }
    }
}
