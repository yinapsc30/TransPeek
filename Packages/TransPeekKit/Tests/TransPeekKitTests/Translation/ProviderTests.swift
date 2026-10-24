import Foundation
import Testing
@testable import TransPeekKit

@Suite("GoogleTranslateProvider")
struct GoogleTranslateProviderTests {
    let request = TranslationRequest(texts: ["hello", "S> Choco 180K"], source: .english, target: .simplifiedChinese)

    @Test("请求格式与响应解析")
    func requestAndResponse() async throws {
        let transport = MockTransport(json: ["data": ["translations": [["translatedText": "你好"], ["translatedText": "卖> 巧克力 180K"]]]])
        let provider = GoogleTranslateProvider(apiKey: "test-key", transport: transport)
        let results = try await provider.translate(request)
        #expect(results.map { try? $0.get() } == ["你好", "卖> 巧克力 180K"])

        let sent = try #require(transport.requests.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url == GoogleTranslateProvider.endpoint)
        #expect(sent.url?.query == nil) // Key 不出现在 URL 中
        #expect(sent.value(forHTTPHeaderField: "X-goog-api-key") == "test-key")
        #expect(sent.timeoutInterval == 10)
        let body = sent.jsonBody
        #expect(body["q"] as? [String] == ["hello", "S> Choco 180K"])
        #expect(body["target"] as? String == "zh-CN")
        #expect(body["source"] as? String == "en")
        #expect(body["format"] as? String == "text")
    }

    @Test("自动检测语言时不传 source")
    func autoDetect() async throws {
        let transport = MockTransport(json: ["data": ["translations": [["translatedText": "x"]]]])
        _ = try await GoogleTranslateProvider(apiKey: "k", transport: transport)
            .translate(TranslationRequest(texts: ["x"], source: nil, target: .simplifiedChinese))
        #expect(transport.requests.first?.jsonBody["source"] == nil)
    }

    @Test("未配置 Key 时不发请求")
    func missingKey() async {
        let transport = MockTransport(json: [:])
        await #expect(throws: TranslationError.notConfigured("未配置 Google API Key，请在设置中填写")) {
            try await GoogleTranslateProvider(apiKey: "", transport: transport).translate(request)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("错误码映射", arguments: [
        (400, false), (403, false), (429, true), (500, true), (503, true),
    ])
    func errorMapping(status: Int, retryable: Bool) async {
        let transport = MockTransport(status: status, json: ["error": ["code": status, "message": "boom"]])
        do {
            _ = try await GoogleTranslateProvider(apiKey: "k", transport: transport).translate(request)
            Issue.record("应当抛出错误")
        } catch let error as TranslationError {
            #expect(error == .http(status: status, message: "boom"))
            #expect(error.isRetryable == retryable)
        } catch {
            Issue.record("错误类型不对：\(error)")
        }
    }

    @Test("网络超时映射为 timeout")
    func timeout() async {
        let transport = MockTransport { _, _ in throw URLError(.timedOut) }
        await #expect(throws: TranslationError.timeout) {
            try await GoogleTranslateProvider(apiKey: "k", transport: transport).translate(request)
        }
    }
}

@Suite("LLM 预设与配置校验")
struct LLMPresetTests {
    @Test("预设文件能解码，包含 11 个预设且字段完整")
    func bundledPresets() throws {
        let presets = LLMPresetCatalog.bundled.presets
        #expect(presets.count == 11)
        #expect(Set(presets.map(\.id)).count == presets.count)
        for preset in presets where preset.id != LLMPreset.customID {
            #expect(!preset.name.isEmpty)
            #expect(preset.modelsDocURL?.scheme == "https", "\(preset.id) 缺少模型文档链接")
            #expect(LLMConfigValidator.validateBaseURL(preset.baseURL).isSuccess, "\(preset.id) 的 Base URL 无效")
        }
        let custom = try #require(LLMPresetCatalog.bundled.preset(id: LLMPreset.customID))
        #expect(custom.baseURL.isEmpty && custom.modelsDocURL == nil)
        #expect(LLMPresetCatalog.bundled.preset(id: "anthropic")?.protocol == .anthropic)
        #expect(LLMPresetCatalog.bundled.preset(id: "ollama")?.requiresAPIKey == false)
    }

    @Test("Base URL 校验", arguments: [
        ("https://api.openai.com/v1", true),
        ("http://localhost:11434/v1", true),
        ("http://127.0.0.1:1234/v1", true),
        ("http://[::1]:8080/v1", true),
        ("http://192.168.1.20:8000/v1", true),
        ("http://10.0.0.5/v1", true),
        ("http://172.20.1.1/v1", true),
        ("http://mac-studio.local:11434/v1", true),
        ("http://api.example.com/v1", false),
        ("http://172.32.0.1/v1", false),
        ("http://8.8.8.8/v1", false),
        ("ftp://localhost/v1", false),
        ("not a url", false),
        ("", false),
    ])
    func baseURL(string: String, valid: Bool) {
        #expect(LLMConfigValidator.validateBaseURL(string).isSuccess == valid)
    }

    @Test("模型 ID 为空时拒绝保存，首尾空白被去掉")
    func model() {
        #expect(LLMConfigValidator.validateModel("  ") == .failure(.emptyModel))
        #expect(LLMConfigValidator.validateModel(" deepseek-flash \n") == .success("deepseek-flash"))
    }

    @Test("额外请求参数必须是 JSON 对象")
    func extraBody() {
        #expect(LLMConfigValidator.validateExtraBody(nil).isSuccess)
        #expect(LLMConfigValidator.validateExtraBody("  ").isSuccess)
        #expect(LLMConfigValidator.validateExtraBody(#"{"thinking": {"type": "disabled"}}"#).isSuccess)
        #expect(!LLMConfigValidator.validateExtraBody("[1, 2]").isSuccess)
        #expect(!LLMConfigValidator.validateExtraBody("{bad json").isSuccess)
    }
}

@Suite("LLM 客户端")
struct LLMClientTests {
    func config(_ protocolKind: LLMProtocol = .openAICompatible, base: String = "https://api.example.com/v1", extra: String? = nil) -> LLMConfig {
        LLMConfig(presetID: "custom", protocolKind: protocolKind, baseURL: URL(string: base)!, model: "test-model", temperature: 0.2, extraBody: extra)
    }

    let completion = LLMCompletionRequest(system: "SYS", user: "USER", maxTokens: 512, jsonMode: true)

    @Test("OpenAI 兼容：请求头、请求体和响应")
    func openAI() async throws {
        let transport = MockTransport { _, _ in (200, openAIResponse("hello")) }
        let client = OpenAICompatibleClient(config: config(base: "https://api.example.com/v1/"), apiKey: "sk-1", transport: transport)
        #expect(try await client.complete(completion) == "hello")

        let sent = try #require(transport.requests.first)
        #expect(sent.url?.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1")
        #expect(sent.timeoutInterval == 30)
        let body = sent.jsonBody
        #expect(body["model"] as? String == "test-model")
        #expect(body["max_tokens"] as? Int == 512)
        #expect(body["temperature"] as? Double == 0.2)
        #expect((body["response_format"] as? [String: String])?["type"] == "json_object")
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": "SYS"], ["role": "user", "content": "USER"]])
    }

    @Test("OpenAI 兼容：无 Key 时不带 Authorization；不支持 JSON 模式时不带 response_format")
    func openAIWithoutKey() async throws {
        let transport = MockTransport { _, _ in (200, openAIResponse("x")) }
        let client = OpenAICompatibleClient(config: config(base: "http://localhost:11434/v1"), apiKey: nil, transport: transport)
        _ = try await client.complete(LLMCompletionRequest(system: "s", user: "u", maxTokens: 256, jsonMode: false))
        let sent = try #require(transport.requests.first)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(sent.jsonBody["response_format"] == nil)
    }

    @Test("额外请求参数浅合并，用户参数优先，null 删除参数")
    func extraBodyMerge() async throws {
        let extra = #"{"temperature": 0.7, "max_tokens": null, "max_completion_tokens": 1024, "thinking": {"type": "disabled"}}"#
        let transport = MockTransport { _, _ in (200, openAIResponse("x")) }
        _ = try await OpenAICompatibleClient(config: config(extra: extra), apiKey: "k", transport: transport).complete(completion)
        let body = try #require(transport.requests.first).jsonBody
        #expect(body["temperature"] as? Double == 0.7)
        #expect(body["max_tokens"] == nil)
        #expect(body["max_completion_tokens"] as? Int == 1024)
        #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
    }

    @Test("Anthropic：请求头、请求体和响应")
    func anthropic() async throws {
        let response = jsonData(["content": [["type": "thinking", "thinking": "..."], ["type": "text", "text": "你好"]]])
        let transport = MockTransport { _, _ in (200, response) }
        let client = AnthropicClient(config: config(.anthropic, base: "https://api.anthropic.com"), apiKey: "ak-1", transport: transport)
        #expect(try await client.complete(completion) == "你好")

        let sent = try #require(transport.requests.first)
        #expect(sent.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == "ak-1")
        #expect(sent.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = sent.jsonBody
        #expect(body["system"] as? String == "SYS")
        #expect(body["max_tokens"] as? Int == 512)
        #expect(body["response_format"] == nil)
        #expect(body["messages"] as? [[String: String]] == [["role": "user", "content": "USER"]])
    }

    @Test("模型 ID 错误时提示检查模型 ID", arguments: [400, 404])
    func modelNotFound(status: Int) async {
        let transport = MockTransport(status: status, json: ["error": ["message": "The model `gpt-x` does not exist"]])
        await #expect(throws: TranslationError.modelNotFound("The model `gpt-x` does not exist")) {
            try await OpenAICompatibleClient(config: config(), apiKey: "k", transport: transport).complete(completion)
        }
    }

    @Test("401 不可重试，500 可重试")
    func statusMapping() async {
        for (status, retryable) in [(401, false), (500, true)] {
            let transport = MockTransport(status: status, json: ["error": ["message": "x"]])
            do {
                _ = try await AnthropicClient(config: config(.anthropic), apiKey: "k", transport: transport).complete(completion)
                Issue.record("应当抛出错误")
            } catch let error as TranslationError {
                #expect(error.isRetryable == retryable)
            } catch {
                Issue.record("错误类型不对")
            }
        }
    }
}

@Suite("PromptBuilder 与 ResponseParser")
struct PromptAndParserTests {
    @Test("system 提示词变量替换")
    func systemVariables() {
        let text = PromptBuilder.system(template: "{source_lang}->{target_lang} @ {app_name}", source: .english, target: .simplifiedChinese, appName: "MapleStory")
        #expect(text == "English->Simplified Chinese @ MapleStory")
        let auto = PromptBuilder.system(template: "{source_lang}|{app_name}", source: nil, target: .english, appName: "")
        #expect(auto == "the detected source language|unknown")
        #expect(PromptBuilder.defaultSystemPrompt.contains("{target_lang}"))
    }

    @Test("user 消息：编号行与截断后的上下文")
    func userMessage() throws {
        let context = (1...8).map { ContextPair(source: "s\($0)", translation: "t\($0)") }
        let message = PromptBuilder.user(lines: ["dragon in 30s", "gg wp"], context: context, contextLimit: 3)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        let lines = try #require(object["lines"] as? [[String: Any]])
        #expect(lines.map { $0["id"] as? Int } == [1, 2])
        #expect(lines.map { $0["text"] as? String } == ["dragon in 30s", "gg wp"])
        let sentContext = try #require(object["context"] as? [[String: String]])
        #expect(sentContext.map { $0["source"] } == ["s6", "s7", "s8"])

        let noContext = PromptBuilder.user(lines: ["x"], context: context, contextLimit: 0)
        #expect(!noContext.contains("context"))
    }

    @Test("max_tokens 估算限制在 256...4096")
    func maxTokens() {
        #expect(PromptBuilder.maxTokens(for: ["hi"]) == 256)
        #expect(PromptBuilder.maxTokens(for: [String(repeating: "a", count: 5000)]) == 4096)
        #expect(PromptBuilder.maxTokens(for: [String(repeating: "a", count: 184)]) == 800)
    }

    @Test("标准 JSON")
    func standard() {
        #expect(ResponseParser.parse(#"{"translations":[{"id":1,"text":"一"},{"id":2,"text":"二"}]}"#, count: 2) == [1: "一", 2: "二"])
    }

    @Test("带代码块标记和多余文字")
    func codeFence() {
        let raw = """
        好的，翻译如下：
        ```json
        {"translations": [{"id": 1, "text": "卖 {巧克力} \\"饼干\\""}]}
        ```
        """
        #expect(ResponseParser.parse(raw, count: 1) == [1: #"卖 {巧克力} "饼干""#])
    }

    @Test("条数不匹配、id 缺失、重复、越界、字符串 id")
    func partial() {
        let raw = #"{"translations":[{"id":"2","text":"二"},{"id":2,"text":"重复"},{"id":5,"text":"越界"},{"text":"无 id"}]}"#
        #expect(ResponseParser.parse(raw, count: 3) == [2: "二"])
    }

    @Test("其他常见形态")
    func shapes() {
        #expect(ResponseParser.parse(#"["一","二"]"#, count: 2) == [1: "一", 2: "二"])
        #expect(ResponseParser.parse(#"[{"id":1,"translation":"一"}]"#, count: 1) == [1: "一"])
        #expect(ResponseParser.parse(#"{"text":"单行"}"#, count: 1) == [1: "单行"])
    }

    @Test("完全无法解析")
    func garbage() {
        #expect(ResponseParser.parse("抱歉，我无法翻译。", count: 2).isEmpty)
        #expect(ResponseParser.parse(#"{"translations": [ {"id": 1"#, count: 1).isEmpty)
    }
}

@Suite("LLMTranslationProvider")
struct LLMTranslationProviderTests {
    let config = LLMConfig(presetID: "openai", protocolKind: .openAICompatible, baseURL: URL(string: "https://api.openai.com/v1")!, model: "m")
    let request = TranslationRequest(texts: ["dragon in 30s", "gg wp"], source: .english, target: .simplifiedChinese, appName: "Game")

    private func provider(_ transport: MockTransport, config: LLMConfig? = nil, missingKey: String? = nil) -> LLMTranslationProvider {
        let config = config ?? self.config
        return LLMTranslationProvider(config: config, client: OpenAICompatibleClient(config: config, apiKey: "k", transport: transport), jsonMode: true, missingKeyReason: missingKey)
    }

    @Test("正常批量翻译，提示词包含语言和应用名")
    func batch() async throws {
        let transport = MockTransport { _, _ in (200, openAIResponse(translationsJSON(["龙 30 秒后刷新", "打得好"]))) }
        let results = try await provider(transport).translate(request)
        #expect(results.map { try? $0.get() } == ["龙 30 秒后刷新", "打得好"])
        #expect(transport.requests.count == 1)
        let system = try #require((transport.requests[0].jsonBody["messages"] as? [[String: String]])?.first?["content"])
        #expect(system.contains("from English to Simplified Chinese") && system.contains("\"Game\""))
    }

    @Test("缺失的行逐行重试一次")
    func perLineRetry() async throws {
        let transport = MockTransport { request, index in
            if index == 0 { return (200, openAIResponse(#"{"translations":[{"id":1,"text":"龙"}]}"#)) }
            // 逐行请求只包含第 2 行
            let user = (request.jsonBody["messages"] as? [[String: String]])?.last?["content"] ?? ""
            #expect(user.contains("gg wp") && !user.contains("dragon"))
            return (200, openAIResponse(#"{"translations":[{"id":1,"text":"打得好"}]}"#))
        }
        let results = try await provider(transport).translate(request)
        #expect(results.map { try? $0.get() } == ["龙", "打得好"])
        #expect(transport.requests.count == 2)
    }

    @Test("逐行重试仍失败时标记该行失败")
    func perLineFailure() async throws {
        let transport = MockTransport { _, index in
            index == 0 ? (200, openAIResponse(#"{"translations":[{"id":2,"text":"打得好"}]}"#)) : (200, openAIResponse("I cannot help with that."))
        }
        let results = try await provider(transport).translate(request)
        #expect(results[1] == .success("打得好"))
        #expect(results[0] == .failure(.invalidResponse("模型没有按要求返回 JSON")))
    }

    @Test("整体请求失败时抛出错误，由服务重试")
    func wholeRequestFailure() async {
        let transport = MockTransport { _, _ in (503, Data("overloaded".utf8)) }
        await #expect(throws: TranslationError.http(status: 503, message: "overloaded")) {
            try await provider(transport).translate(request)
        }
    }

    @Test("未填写 Key 时不发请求")
    func missingKey() async {
        let transport = MockTransport { _, _ in (200, Data()) }
        await #expect(throws: TranslationError.notConfigured("缺少 Key")) {
            try await provider(transport, missingKey: "缺少 Key").translate(request)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("fingerprint 随影响译文的参数变化")
    func fingerprint() {
        let base = LLMTranslationProvider.fingerprint(for: config)
        #expect(base.hasPrefix("llm-") && base.count == 20)
        #expect(LLMTranslationProvider.fingerprint(for: config) == base)
        var changed = config
        changed.model = "other"
        #expect(LLMTranslationProvider.fingerprint(for: changed) != base)
        changed = config
        changed.systemPrompt = "custom"
        #expect(LLMTranslationProvider.fingerprint(for: changed) != base)
        changed = config
        changed.extraBody = #"{"a":1}"#
        #expect(LLMTranslationProvider.fingerprint(for: changed) != base)
        changed = config
        changed.contextCount = 10 // 上下文条数不影响缓存
        #expect(LLMTranslationProvider.fingerprint(for: changed) == base)
    }
}

@Suite("ProviderRegistry")
struct ProviderRegistryTests {
    @Test("LLM 配置开启回退且有 Google Key 时提供回退；配置变化后重建")
    func resolve() async throws {
        let directory = try makeTemporaryDirectory()
        let profiles = TranslationProfileStore(fileURL: directory.appendingPathComponent("p.json"))
        let defaults = UserDefaults(suiteName: "TransPeekKitTests-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        let secrets = InMemorySecretStore([SecretAccount.google: "g-key"])
        let llm = TranslationProfile(name: "DeepSeek", kind: .llm(LLMConfig(
            presetID: "deepseek", protocolKind: .openAICompatible, baseURL: URL(string: "https://api.deepseek.com")!,
            model: "deepseek-flash", fallbackToGoogle: true
        )))
        try profiles.upsert(llm)
        settings.update { $0.defaultProfileID = llm.id }
        let registry = ProviderRegistry(profiles: profiles, settings: settings, secrets: secrets, transport: MockTransport(json: [:]))

        let resolved = try #require(await registry.resolve(nil))
        #expect(resolved.profileID == llm.id)
        #expect(resolved.policy == .llm)
        #expect(resolved.fallback?.fingerprint == "google-v2")

        // 修改模型后自动失效（通过通知异步失效，这里直接调用确保顺序）
        var updated = llm
        updated.kind = .llm(LLMConfig(presetID: "deepseek", protocolKind: .openAICompatible, baseURL: URL(string: "https://api.deepseek.com")!, model: "deepseek-v4-pro"))
        try profiles.upsert(updated)
        await registry.invalidate()
        let rebuilt = try #require(await registry.resolve(llm.id))
        #expect(rebuilt.provider.fingerprint != resolved.provider.fingerprint)
        #expect(rebuilt.fallback == nil)

        let google = try #require(await registry.resolve(profiles.profiles[0].id))
        #expect(google.policy == .google)
    }

    @Test("预设要求 Key 但未填写时返回未配置")
    func missingKey() async throws {
        let profile = TranslationProfile(name: "OpenAI", kind: .llm(LLMConfig(
            presetID: "openai", protocolKind: .openAICompatible, baseURL: URL(string: "https://api.openai.com/v1")!, model: "m"
        )))
        let resolved = ProviderRegistry.makeResolved(profile, secrets: InMemorySecretStore(), transport: MockTransport(json: [:]))
        await #expect(throws: TranslationError.self) {
            try await resolved.provider.translate(TranslationRequest(texts: ["x"], source: nil, target: .english))
        }
        // 本地服务不需要 Key
        let local = TranslationProfile(name: "Ollama", kind: .llm(LLMConfig(
            presetID: "ollama", protocolKind: .openAICompatible, baseURL: URL(string: "http://localhost:11434/v1")!, model: "qwen"
        )))
        let transport = MockTransport { _, _ in (200, openAIResponse(translationsJSON(["好"]))) }
        let localResolved = ProviderRegistry.makeResolved(local, secrets: InMemorySecretStore(), transport: transport)
        #expect(try await localResolved.provider.translate(TranslationRequest(texts: ["ok"], source: nil, target: .simplifiedChinese)) == [.success("好")])
    }
}

extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
