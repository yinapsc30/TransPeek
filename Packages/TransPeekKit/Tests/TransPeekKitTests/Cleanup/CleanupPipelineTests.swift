import CoreGraphics
import Foundation
import Testing
@testable import TransPeekKit

/// 按每行文本返回预设结果的翻译服务，用于模拟智能整理。
actor ScriptedTranslator: TranslationServicing {
    private let outputs: [String: TranslationState]
    private(set) var calls: [(texts: [String], options: TranslationOptions)] = []

    init(_ outputs: [String: TranslationState]) {
        self.outputs = outputs
    }

    func translate(_ texts: [String], options: TranslationOptions) async -> [TranslationState] {
        calls.append((texts, options))
        return texts.map { outputs[$0] ?? .done("译:\($0)") }
    }
}

@Suite("识别结果整理：流水线（C1、C2、C3）")
struct CleanupPipelineTests {
    let frame = makeSolidImage(width: 400, height: 200, gray: 60)!
    static let discord = ["Haka OGLUE 14:39", "isnt it kinda hard to move around ._. (已编辑)", "•", "Archereon - Merc 14:40", "I got a permit today"]

    private func region(mode: RegionMode = .once, filtersNoise: Bool = true, smartCleanup: Bool = true) -> Region {
        Region(name: "r", rect: CGRect(x: 0, y: 0, width: 1, height: 1), mode: mode, sourceLanguage: .english,
               targetLanguage: .simplifiedChinese, filtersNoise: filtersNoise, smartCleanup: smartCleanup)
    }

    private func run(_ region: Region, usesLLM: Bool, ocr: [[String]], translator: any TranslationServicing) async -> EventSink {
        let sink = EventSink()
        let pipeline = RegionPipeline(
            configuration: PipelineConfiguration(region: region, appName: "Discord", usesLLM: usesLLM),
            ocr: ScriptedOCR(ocr), translator: translator, output: sink.output
        )
        for _ in ocr {
            await pipeline.recognizeNow(windowImage: frame)
            await pipeline.waitUntilIdle()
        }
        return sink
    }

    @Test("规则过滤：名字行直接显示、乱码丢弃、标签移除，只翻译消息")
    func ruleFiltering() async {
        let translator = EchoTranslator()
        let sink = await run(region(), usesLLM: false, ocr: [Self.discord], translator: translator)
        guard case let .replaceAll(entries) = sink.events.first else { Issue.record("应为 replaceAll"); return }
        #expect(entries.map(\.original) == ["Haka OGLUE 14:39", "isnt it kinda hard to move around ._.", "Archereon - Merc 14:40", "I got a permit today"])
        #expect(entries.map(\.translation) == [.metadata, .pending, .metadata, .pending])
        let calls = await translator.calls
        #expect(calls.map(\.texts) == [["isnt it kinda hard to move around ._.", "I got a permit today"]])
        #expect(calls.first?.options.classifiesLines == false)
    }

    @Test("关闭过滤时所有行都翻译")
    func filterDisabled() async {
        let translator = EchoTranslator()
        // 目标语言用英语：目标为中文时含中文的“(已编辑)”行不会翻译（R8.9）
        var english = region(filtersNoise: false)
        english.targetLanguage = .english
        _ = await run(english, usesLLM: false, ocr: [Self.discord], translator: translator)
        // 单独的 “•” 在行组装时就被归一化去掉了（R6.5），其余 4 行（含名字行和界面标签）都翻译
        let texts = await translator.calls.first?.texts
        #expect(texts?.count == 4)
        #expect(texts?.contains("isnt it kinda hard to move around ._. (已编辑)") == true)
    }

    @Test("智能整理：名字行交给模型判断，模型标注的类型反映到条目状态")
    func smartCleanup() async {
        let translator = ScriptedTranslator(["Haka OGLUE 14:39": .metadata, "Black Kottyn NotCreative": .hidden])
        let sink = await run(region(), usesLLM: true, ocr: [["Black Kottyn NotCreative", "Haka OGLUE 14:39", "gg wp"]], translator: translator)
        let calls = await translator.calls
        #expect(calls.first?.options.classifiesLines == true)
        // 规则不再标记名字行，三行都交给模型
        #expect(calls.first?.texts == ["Black Kottyn NotCreative", "Haka OGLUE 14:39", "gg wp"])
        let updates = sink.updates
        #expect(updates.count == 3 && updates.contains(.hidden) && updates.contains(.metadata) && updates.contains(.done("译:gg wp")))
    }

    @Test("对话模式不标注类型；Google 翻译时智能整理不生效")
    func notClassified() async {
        let dialog = EchoTranslator()
        _ = await run(region(mode: .dialog), usesLLM: true, ocr: [["Elder: The bridge is out."]], translator: dialog)
        #expect(await dialog.calls.first?.options.classifiesLines == false)

        let google = EchoTranslator()
        _ = await run(region(), usesLLM: false, ocr: [["gg wp"]], translator: google)
        #expect(await google.calls.first?.options.classifiesLines == false)

        let disabled = EchoTranslator()
        _ = await run(region(smartCleanup: false), usesLLM: true, ocr: [["gg wp"]], translator: disabled)
        #expect(await disabled.calls.first?.options.classifiesLines == false)
    }

    @Test("名字/时间行参与聊天去重对齐（C1.5）")
    func metadataAnchorsChatDiff() async {
        let translator = EchoTranslator()
        let sink = await run(region(mode: .chat), usesLLM: false, ocr: [
            ["Haka OGLUE 14:39", "isnt it kinda hard to move", "Archereon - Merc 14:40"],
            ["Archereon - Merc 14:40", "I got a permit today"],
        ], translator: translator)
        #expect(sink.originals == ["Haka OGLUE 14:39", "isnt it kinda hard to move", "Archereon - Merc 14:40", "I got a permit today"])
    }

    @Test("PanelHistory：.hidden 删除条目并减少新消息数，名字行不计入新消息")
    func panelHistory() {
        var history = PanelHistory()
        let id = UUID()
        let name = Entry(regionID: id, original: "Haka 14:39", translation: .metadata)
        let message = Entry(regionID: id, original: "gg")
        let noise = Entry(regionID: id, original: "Black Kottyn")
        #expect(history.apply(.append([name, message, noise])) == 2)
        #expect(history.apply(.update(entryID: noise.id, state: .hidden)) == -1)
        #expect(history.entries.map(\.original) == ["Haka 14:39", "gg"])
        #expect(history.apply(.update(entryID: UUID(), state: .hidden)) == 0)
        history.apply(.update(entryID: message.id, state: .done("打得好")))
        #expect(history.plainText(includeOriginal: false) == "Haka 14:39\n打得好")
    }
}

@Suite("识别结果整理：翻译（C2）")
struct CleanupTranslationTests {
    @Test("Region 旧数据解码：按模式取默认值；新字段往返编码")
    func regionDecoding() throws {
        let chat = Region(name: "c", rect: CGRect(x: 0, y: 0, width: 1, height: 1), mode: .chat, targetLanguage: .english)
        var json = try JSONSerialization.jsonObject(with: JSONCoding.encoder().encode(chat)) as! [String: Any]
        json.removeValue(forKey: "filtersNoise")
        json.removeValue(forKey: "smartCleanup")
        json["mode"] = "dialog"
        let legacy = try JSONCoding.decoder().decode(Region.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.filtersNoise == false && legacy.smartCleanup == true)
        json["mode"] = "chat"
        #expect(try JSONCoding.decoder().decode(Region.self, from: JSONSerialization.data(withJSONObject: json)).filtersNoise == true)

        var custom = chat
        custom.filtersNoise = false
        custom.smartCleanup = false
        #expect(try roundTrip(custom) == custom)
        #expect(chat.filtersNoise == true)
    }

    @Test("输出格式：标注模式说明 type；自定义提示词也附加格式")
    func outputFormat() {
        let plain = PromptBuilder.fullSystem(template: "Translate to {target_lang}.", source: nil, target: .english, appName: "", classifiesLines: false)
        #expect(plain.hasPrefix("Translate to English.") && plain.contains(#"{"id": 1, "text": "..."}"#) && !plain.contains("\"type\""))
        let classified = PromptBuilder.fullSystem(template: "Custom.", source: nil, target: .english, appName: "", classifiesLines: true)
        #expect(classified.contains(#""type": "message""#) && classified.contains("\"name\"") && classified.contains("\"ui\""))
        #expect(!PromptBuilder.defaultSystemPrompt.contains("Output JSON"))
    }

    @Test("解析 type：name → metadata，ui → hidden，缺失或未知 → 消息")
    func parseTypes() {
        let raw = #"{"translations":[{"id":1,"type":"name","text":""},{"id":2,"type":"ui","text":""},{"id":3,"type":"message","text":"打得好"},{"id":4,"text":"无类型"},{"id":5,"type":"weird","text":"未知"},{"id":6,"type":"message"}]}"#
        let parsed = ResponseParser.parseOutputs(raw, count: 6)
        #expect(parsed == [1: .metadata, 2: .hidden, 3: "打得好", 4: "无类型", 5: "未知"])
        #expect(ResponseParser.parse(raw, count: 6) == [3: "打得好", 4: "无类型", 5: "未知"])
    }

    @Test("开启和关闭智能整理时分开缓存、分开合并")
    func separateCacheAndBatches() async {
        let provider = MockProvider(otherwise: { request in
            request.texts.map { request.classifiesLines ? .success(.metadata) : .success(.translated("译:\($0)")) }
        })
        let service = TranslationService(resolver: StaticResolver(resolved: ResolvedProvider(
            profileID: UUID(), provider: provider, policy: BatchPolicy(window: .milliseconds(40), maxBatchSize: 100, maxConcurrentRequests: 4)
        )))
        let classify = TranslationOptions(source: .english, target: .simplifiedChinese, classifiesLines: true)
        let plain = TranslationOptions(source: .english, target: .simplifiedChinese)

        async let a = service.translate(["Haka 14:39"], options: classify)
        async let b = service.translate(["Haka 14:39"], options: plain)
        let (ra, rb) = await (a, b)
        #expect(ra == [.metadata] && rb == [.done("译:Haka 14:39")])
        #expect(await provider.calls.count == 2)

        // 再次请求都命中缓存
        #expect(await service.translate(["Haka 14:39"], options: classify) == [.metadata])
        #expect(await provider.calls.count == 2)
    }

    @Test("LLM provider：标注模式下返回类型")
    func llmProviderClassifies() async throws {
        let config = LLMConfig(presetID: "openai", protocolKind: .openAICompatible, baseURL: URL(string: "https://api.openai.com/v1")!, model: "m")
        let transport = MockTransport { request, _ in
            let system = (request.jsonBody["messages"] as? [[String: String]])?.first?["content"] ?? ""
            #expect(system.contains("\"type\""))
            return (200, openAIResponse(#"{"translations":[{"id":1,"type":"name","text":""},{"id":2,"type":"message","text":"打得好"}]}"#))
        }
        let provider = LLMTranslationProvider(config: config, client: OpenAICompatibleClient(config: config, apiKey: "k", transport: transport), jsonMode: true)
        let results = try await provider.translate(TranslationRequest(texts: ["Haka 14:39", "gg wp"], source: .english, target: .simplifiedChinese, classifiesLines: true))
        #expect(results == [.success(.metadata), .success("打得好")])
        #expect(transport.requests.count == 1)
    }
}
