import Foundation
import Testing
@testable import TransPeekKit

/// 按脚本返回结果并记录调用的 provider。
actor MockProvider: TranslationProvider {
    nonisolated let fingerprint: String
    private(set) var calls: [TranslationRequest] = []
    private var script: [(TranslationRequest) throws -> [Result<TranslationOutput, TranslationError>]]
    private let fallbackBehavior: (TranslationRequest) throws -> [Result<TranslationOutput, TranslationError>]
    private let delay: Duration

    init(
        fingerprint: String = "mock",
        delay: Duration = .zero,
        script: [(TranslationRequest) throws -> [Result<TranslationOutput, TranslationError>]] = [],
        otherwise: @escaping (TranslationRequest) throws -> [Result<TranslationOutput, TranslationError>] = { request in
            request.texts.map { .success("译:\($0)") }
        }
    ) {
        self.fingerprint = fingerprint
        self.delay = delay
        self.script = script
        self.fallbackBehavior = otherwise
    }

    func translate(_ request: TranslationRequest) async throws -> [Result<TranslationOutput, TranslationError>] {
        calls.append(request)
        if delay > .zero { try await Task.sleep(for: delay) }
        if !script.isEmpty { return try script.removeFirst()(request) }
        return try fallbackBehavior(request)
    }
}

struct StaticResolver: ProviderResolving {
    let resolved: ResolvedProvider?
    func resolve(_ profileID: UUID?) async -> ResolvedProvider? { resolved }
}

@Suite("TranslationCache")
struct TranslationCacheTests {
    private func key(_ text: String, _ fingerprint: String = "f") -> TranslationCacheKey {
        TranslationCacheKey(text: text, source: nil, target: .simplifiedChinese, fingerprint: fingerprint)
    }

    @Test("命中与 LRU 淘汰")
    func lru() {
        var cache = TranslationCache(capacity: 2)
        cache.insert("A", for: key("a"))
        cache.insert("B", for: key("b"))
        #expect(cache.value(for: key("a")) == "A") // a 变为最近使用
        cache.insert("C", for: key("c"))           // 淘汰 b
        #expect(cache.value(for: key("b")) == nil)
        #expect(cache.value(for: key("a")) == "A")
        #expect(cache.value(for: key("c")) == "C")
        #expect(cache.count == 2)
    }

    @Test("不同 fingerprint、语言互不影响")
    func isolation() {
        var cache = TranslationCache()
        cache.insert("google", for: key("gg", "google-v2"))
        #expect(cache.value(for: key("gg", "llm-1")) == nil)
        let japanese = TranslationCacheKey(text: "gg", source: nil, target: Language("ja"), fingerprint: "google-v2")
        #expect(cache.value(for: japanese) == nil)
    }
}

@Suite("TranslationService")
struct TranslationServiceTests {
    let options = TranslationOptions(source: .english, target: .simplifiedChinese, appName: "Game")
    let fastPolicy = BatchPolicy(window: .milliseconds(40), maxBatchSize: 100, maxConcurrentRequests: 4)

    private func service(_ provider: MockProvider, fallback: MockProvider? = nil, policy: BatchPolicy? = nil, sleeper: any Sleeper = TaskSleeper()) -> TranslationService {
        TranslationService(
            resolver: StaticResolver(resolved: ResolvedProvider(profileID: UUID(), provider: provider, fallback: fallback, policy: policy ?? fastPolicy)),
            sleeper: sleeper
        )
    }

    @Test("缓存命中时不发请求")
    func cacheHit() async {
        let provider = MockProvider()
        let service = service(provider)
        #expect(await service.translate(["gg"], options: options) == [.done("译:gg")])
        #expect(await service.translate(["gg"], options: options) == [.done("译:gg")])
        #expect(await provider.calls.count == 1)
    }

    @Test("上下文不参与缓存键")
    func contextIgnoredByCache() async {
        let provider = MockProvider()
        let service = service(provider)
        var withContext = options
        withContext.context = [ContextPair(source: "hi", translation: "嗨")]
        _ = await service.translate(["gg"], options: options)
        _ = await service.translate(["gg"], options: withContext)
        #expect(await provider.calls.count == 1)
    }

    @Test("合并窗口内的多条文本合并为一次请求，顺序与输入一致")
    func batching() async {
        let provider = MockProvider()
        let service = service(provider)
        async let first = service.translate(["a1", "a2"], options: options)
        async let second = service.translate(["b1"], options: options)
        let (r1, r2) = await (first, second)
        #expect(r1 == [.done("译:a1"), .done("译:a2")])
        #expect(r2 == [.done("译:b1")])
        let calls = await provider.calls
        #expect(calls.count == 1)
        #expect(Set(calls[0].texts) == ["a1", "a2", "b1"])
        #expect(calls[0].appName == "Game")
    }

    @Test("达到批量上限时立即发送并拆分")
    func maxBatchSize() async {
        let provider = MockProvider()
        let service = service(provider, policy: BatchPolicy(window: .seconds(5), maxBatchSize: 2, maxConcurrentRequests: 4))
        let results = await service.translate(["1", "2", "3", "4"], options: options)
        #expect(results.count == 4)
        #expect(await provider.calls.map(\.texts.count) == [2, 2])
    }

    @Test("同一文本的并发请求只发一次")
    func dedupe() async {
        let provider = MockProvider(delay: .milliseconds(50))
        let service = service(provider)
        async let a = service.translate(["same"], options: options)
        async let b = service.translate(["same"], options: options)
        async let c = service.translate(["same", "same"], options: options)
        let (ra, rb, rc) = await (a, b, c)
        #expect(ra == [.done("译:same")] && rb == ra && rc == [.done("译:same"), .done("译:same")])
        let calls = await provider.calls
        #expect(calls.count == 1 && calls[0].texts == ["same"])
    }

    @Test("可重试错误按 0.5s / 1s / 2s 退避，第 4 次成功")
    func retryBackoff() async {
        let provider = MockProvider(script: [
            { _ in throw TranslationError.timeout },
            { _ in throw TranslationError.http(status: 503, message: "busy") },
            { _ in throw TranslationError.http(status: 429, message: "slow down") },
        ])
        let sleeper = RecordingSleeper()
        let service = service(provider, sleeper: sleeper)
        #expect(await service.translate(["x"], options: options) == [.done("译:x")])
        #expect(await provider.calls.count == 4)
        // 第一项是合并窗口，其后是三次退避
        #expect(sleeper.durations.dropFirst() == [.milliseconds(500), .seconds(1), .seconds(2)])
    }

    @Test("重试 3 次后仍失败则标记失败")
    func retryExhausted() async {
        let provider = MockProvider(otherwise: { _ in throw TranslationError.timeout })
        let service = service(provider, sleeper: RecordingSleeper())
        let result = await service.translate(["x"], options: options)
        #expect(result == [.failed(TranslationError.timeout.localizedDescription)])
        #expect(await provider.calls.count == 4)
    }

    @Test("不可重试错误不重试；未配置 Key 显示为不可用")
    func nonRetryable() async {
        let forbidden = MockProvider(otherwise: { _ in throw TranslationError.http(status: 403, message: "quota") })
        let result = await service(forbidden, sleeper: RecordingSleeper()).translate(["x"], options: options)
        #expect(await forbidden.calls.count == 1)
        guard case .failed = result.first else { Issue.record("应为失败"); return }

        let missingKey = MockProvider(otherwise: { _ in throw TranslationError.notConfigured("未配置") })
        #expect(await service(missingKey).translate(["x"], options: options) == [.unavailable("未配置")])
    }

    @Test("失败时回退到 Google 并标记，回退结果不写入缓存")
    func fallback() async {
        let primary = MockProvider(otherwise: { request in
            request.texts.map { $0 == "bad" ? .failure(.invalidResponse("x")) : .success("LLM:\($0)") }
        })
        let google = MockProvider(fingerprint: "google-v2", otherwise: { request in request.texts.map { .success("G:\($0)") } })
        let service = service(primary, fallback: google)
        let results = await service.translate(["good", "bad"], options: options)
        #expect(results == [.done("LLM:good"), .done("G:bad", fallback: true)])
        #expect(await google.calls.map(\.texts) == [["bad"]])

        _ = await service.translate(["bad"], options: options)
        #expect(await primary.calls.count == 2) // 回退结果没有缓存，会再次请求主 provider
    }

    @Test("没有可用配置时全部不可用")
    func noProfile() async {
        let service = TranslationService(resolver: StaticResolver(resolved: nil))
        #expect(await service.translate(["a", "b"], options: options) == [.unavailable("没有可用的翻译配置"), .unavailable("没有可用的翻译配置")])
    }

    @Test("返回条数不一致视为无效响应")
    func countMismatch() async {
        let provider = MockProvider(otherwise: { _ in [.success("only one")] })
        let results = await service(provider).translate(["a", "b"], options: options)
        #expect(results.allSatisfy { if case .failed = $0 { true } else { false } })
    }

    @Test("空文本直接返回空译文")
    func emptyText() async {
        let provider = MockProvider()
        #expect(await service(provider).translate([""], options: options) == [.done("")])
        #expect(await provider.calls.isEmpty)
    }
}
