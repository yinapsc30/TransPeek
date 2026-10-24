import CoreGraphics
import Foundation
import Testing
@testable import TransPeekKit

/// 按脚本返回识别结果的 OCR 引擎，每次调用返回下一组行。
actor ScriptedOCR: OCREngine {
    private var script: [[String]]
    private let delay: Duration
    private(set) var calls = 0
    private(set) var languages: [[String]?] = []

    init(_ script: [[String]], delay: Duration = .zero) {
        self.script = script
        self.delay = delay
    }

    func recognize(_ image: CGImage, languages: [String]?) async throws -> [OCRFragment] {
        calls += 1
        self.languages.append(languages)
        if delay > .zero { try await Task.sleep(for: delay) }
        let lines = script.isEmpty ? [] : script.removeFirst()
        return lines.enumerated().map { index, text in
            OCRFragment(text: text, confidence: 1, box: CGRect(x: 0.05, y: 0.1 + Double(index) * 0.2, width: 0.9, height: 0.15))
        }
    }
}

/// 原样加前缀返回的翻译服务，并记录每次调用的参数。
actor EchoTranslator: TranslationServicing {
    private(set) var calls: [(texts: [String], options: TranslationOptions)] = []

    func translate(_ texts: [String], options: TranslationOptions) async -> [TranslationState] {
        calls.append((texts, options))
        return texts.map { .done("译:\($0)") }
    }
}

/// 收集流水线事件。
final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [PipelineEvent] = []

    var events: [PipelineEvent] { lock.withLock { _events } }

    var output: RegionPipeline.Output {
        { [weak self] event in self?.record(event) }
    }

    private func record(_ event: PipelineEvent) {
        lock.withLock { _events.append(event) }
    }

    /// 所有追加/替换/对话事件中的原文。
    var originals: [String] {
        events.flatMap { event -> [String] in
            switch event {
            case let .append(entries), let .replaceAll(entries): entries.map { $0.kind == .gapMarker ? "<gap>" : $0.original }
            case let .dialog(entry): [entry.original]
            case .update: []
            }
        }
    }

    var updates: [TranslationState] {
        events.compactMap { if case let .update(_, state) = $0 { state } else { nil } }
    }
}

@Suite("RegionPipeline")
struct RegionPipelineTests {
    let frameA = makeSolidImage(width: 400, height: 200, gray: 20)!
    let frameB = makeSolidImage(width: 400, height: 200, gray: 200)!
    let frameC = makeSolidImage(width: 400, height: 200, gray: 110)!

    private func makePipeline(
        mode: RegionMode, ocr: ScriptedOCR, translator: EchoTranslator = EchoTranslator(), sink: EventSink,
        source: Language? = .english, paused: Bool = false
    ) -> RegionPipeline {
        let region = Region(
            name: "测试", rect: CGRect(x: 0, y: 0, width: 1, height: 1), mode: mode,
            sourceLanguage: source, targetLanguage: .simplifiedChinese, isPaused: paused
        )
        return RegionPipeline(
            configuration: PipelineConfiguration(region: region, appName: "Game"),
            ocr: ocr, translator: translator, output: sink.output
        )
    }

    /// 以 4fps 连续提交同一帧，直到触发识别。
    private func feed(_ pipeline: RegionPipeline, _ frame: CGImage, from start: TimeInterval, frames: Int = 2) async {
        for index in 0..<frames {
            await pipeline.submit(windowImage: frame, at: start + Double(index) * 0.25)
        }
        await pipeline.waitUntilIdle()
    }

    @Test("聊天模式：只追加新行，翻译带上下文")
    func chatMode() async {
        let ocr = ScriptedOCR([["alpha says hi", "bravo sells sword"], ["bravo sells sword", "charlie buys pot"]])
        let translator = EchoTranslator()
        let sink = EventSink()
        let pipeline = makePipeline(mode: .chat, ocr: ocr, translator: translator, sink: sink)

        await feed(pipeline, frameA, from: 0)
        await feed(pipeline, frameB, from: 1)
        await feed(pipeline, frameB, from: 2) // 画面没有变化，不再识别

        #expect(await ocr.calls == 2)
        #expect(await ocr.languages.first == ["en-US"])
        #expect(sink.originals == ["alpha says hi", "bravo sells sword", "charlie buys pot"])
        #expect(sink.updates == [.done("译:alpha says hi"), .done("译:bravo sells sword"), .done("译:charlie buys pot")])

        let calls = await translator.calls
        #expect(calls.count == 2)
        #expect(calls[0].options.context.isEmpty)
        #expect(calls[1].options.context.map(\.source) == ["alpha says hi", "bravo sells sword"])
        #expect(calls[1].options.appName == "Game" && calls[1].options.target == .simplifiedChinese)
    }

    @Test("聊天模式：两次结果没有重叠时插入遗漏标记；识别为空时保留上次结果")
    func chatGapAndEmpty() async {
        let ocr = ScriptedOCR([["alpha says hi"], [], ["xray wts bow"]])
        let sink = EventSink()
        let pipeline = makePipeline(mode: .chat, ocr: ocr, sink: sink)
        await feed(pipeline, frameA, from: 0)
        await feed(pipeline, frameB, from: 1)
        await feed(pipeline, frameC, from: 2)
        #expect(sink.originals == ["alpha says hi", "<gap>", "xray wts bow"])
    }

    @Test("对话模式：相似文本不更新，新文本替换")
    func dialogMode() async {
        let ocr = ScriptedOCR([["Hello traveler,", "the bridge is out."], ["Hello traveler,", "the bridge is 0ut."], ["Take the north road."]])
        let sink = EventSink()
        let pipeline = makePipeline(mode: .dialog, ocr: ocr, sink: sink)
        await feed(pipeline, frameA, from: 0)
        await feed(pipeline, frameB, from: 1)
        await feed(pipeline, frameC, from: 2)
        #expect(await ocr.calls == 3)
        #expect(sink.originals == ["Hello traveler, the bridge is out.", "Take the north road."])
    }

    @Test("单次模式：不响应持续帧，手动触发时替换全部内容")
    func onceMode() async {
        let ocr = ScriptedOCR([["Sword of Dawn", "ATK +12"]])
        let sink = EventSink()
        let pipeline = makePipeline(mode: .once, ocr: ocr, sink: sink, source: nil)
        await feed(pipeline, frameA, from: 0)
        #expect(await ocr.calls == 0)

        await pipeline.recognizeNow(windowImage: frameA)
        await pipeline.waitUntilIdle()
        #expect(await ocr.calls == 1)
        #expect(await ocr.languages.first == .some(nil)) // 自动检测语言
        guard case let .replaceAll(entries) = sink.events.first else { Issue.record("应为 replaceAll"); return }
        #expect(entries.map(\.original) == ["Sword of Dawn", "ATK +12"])
    }

    @Test("画面没有变化时不调用 OCR；暂停的区域不识别")
    func noChangeNoOCR() async {
        let ocr = ScriptedOCR([["a line here"]])
        let sink = EventSink()
        let pipeline = makePipeline(mode: .chat, ocr: ocr, sink: sink)
        await feed(pipeline, frameA, from: 0, frames: 8)
        #expect(await ocr.calls == 1)

        let pausedOCR = ScriptedOCR([["x"]])
        let pausedSink = EventSink()
        let paused = makePipeline(mode: .chat, ocr: pausedOCR, sink: pausedSink, paused: true)
        await feed(paused, frameA, from: 0)
        #expect(await pausedOCR.calls == 0)
    }

    @Test("OCR 进行中只保留最新的待处理帧")
    func coalescesPendingFrames() async {
        let ocr = ScriptedOCR([["first one"], ["second one"], ["third one"]], delay: .milliseconds(80))
        let sink = EventSink()
        let pipeline = makePipeline(mode: .once, ocr: ocr, sink: sink)
        await pipeline.recognizeNow(windowImage: frameA)
        await pipeline.recognizeNow(windowImage: frameB) // 进入 pending
        await pipeline.recognizeNow(windowImage: frameC) // 替换 pending
        await pipeline.waitUntilIdle()
        #expect(await ocr.calls == 2)
    }

    @Test("修改区域位置后重置识别状态")
    func resetOnRectChange() async {
        let ocr = ScriptedOCR([["alpha says hi"], ["alpha says hi"]])
        let sink = EventSink()
        let pipeline = makePipeline(mode: .chat, ocr: ocr, sink: sink)
        await feed(pipeline, frameA, from: 0)

        var configuration = PipelineConfiguration(region: await pipeline.region, appName: "Game")
        configuration.region.rect = CGRect(x: 0, y: 0, width: 1, height: 0.5)
        await pipeline.update(configuration)
        await feed(pipeline, frameA, from: 1)
        #expect(await ocr.calls == 2)
        #expect(sink.originals == ["alpha says hi", "alpha says hi"])
    }

    @Test("手动重试失败的条目")
    func retry() async {
        let translator = EchoTranslator()
        let sink = EventSink()
        let pipeline = makePipeline(mode: .chat, ocr: ScriptedOCR([]), translator: translator, sink: sink)
        let failed = Entry(regionID: UUID(), original: "need heal", translation: .failed("timeout"))
        await pipeline.retry(failed)
        await pipeline.waitUntilIdle()
        #expect(sink.events == [.update(entryID: failed.id, state: .pending), .update(entryID: failed.id, state: .done("译:need heal"))])
    }
}

@Suite("PanelHistory")
struct PanelHistoryTests {
    let regionID = UUID()

    @Test("追加、更新与历史上限")
    func appendUpdateLimit() {
        var history = PanelHistory(limit: 3)
        let entries = (1...4).map { Entry(regionID: regionID, original: "line \($0)") }
        #expect(history.apply(.append(Array(entries.prefix(2)))) == 2)
        history.apply(.append([.gapMarker(regionID: regionID)] + entries.suffix(2)))
        #expect(history.entries.count == 3)
        #expect(history.entries.map(\.original) == ["", "line 3", "line 4"])

        history.apply(.update(entryID: entries[3].id, state: .done("第四行")))
        #expect(history.entry(id: entries[3].id)?.translation == .done("第四行"))

        history.limit = 1
        #expect(history.entries.map(\.original) == ["line 4"])
    }

    @Test("对话模式：新文本进入顶部，旧文本进入历史")
    func dialog() {
        var history = PanelHistory()
        let first = Entry(regionID: regionID, original: "Hello", kind: .dialogSnapshot)
        let second = Entry(regionID: regionID, original: "Bye", kind: .dialogSnapshot)
        history.apply(.dialog(first))
        history.apply(.update(entryID: first.id, state: .done("你好")))
        history.apply(.dialog(second))
        #expect(history.currentDialog?.original == "Bye")
        #expect(history.entries.map(\.original) == ["Hello"])
        #expect(history.entries.first?.translation == .done("你好"))
    }

    @Test("单次模式替换全部内容；清空历史；复制全部")
    func replaceAndCopy() {
        var history = PanelHistory()
        history.apply(.append([Entry(regionID: regionID, original: "old")]))
        let item = Entry(regionID: regionID, original: "Sword", translation: .done("剑"))
        history.apply(.replaceAll([item, Entry(regionID: regionID, original: "ATK +12", translation: .done("ATK +12"))]))
        #expect(history.plainText(includeOriginal: false) == "剑\nATK +12")
        #expect(history.plainText(includeOriginal: true) == "剑\nSword\nATK +12")
        history.clear()
        #expect(history.entries.isEmpty && history.currentDialog == nil)
    }
}
