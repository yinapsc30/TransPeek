import Foundation
import OSLog

/// 区域发起翻译时的参数。
public struct TranslationOptions: Sendable, Equatable {
    public var source: Language?
    public var target: Language
    /// `nil` 表示使用全局默认翻译配置（R16.7）。
    public var profileID: UUID?
    /// 最近已翻译条目，LLM provider 会按配置的上下文条数截断（R16.9）。
    public var context: [ContextPair]
    public var appName: String
    /// LLM 智能整理：让模型标注每行的类型（ocr-cleanup C2.2）。
    public var classifiesLines: Bool

    public init(source: Language?, target: Language, profileID: UUID? = nil, context: [ContextPair] = [], appName: String = "", classifiesLines: Bool = false) {
        self.source = source
        self.target = target
        self.profileID = profileID
        self.context = context
        self.appName = appName
        self.classifiesLines = classifiesLines
    }
}

/// 区域流水线依赖的翻译接口，便于测试替换。
public protocol TranslationServicing: Sendable {
    /// 返回值与 `texts` 一一对应，且都是最终状态（不会是 `.pending`）。
    func translate(_ texts: [String], options: TranslationOptions) async -> [TranslationState]
}

/// 已解析的翻译配置：provider、回退 provider 和批量策略。
public struct ResolvedProvider: Sendable {
    public let profileID: UUID
    public let provider: any TranslationProvider
    /// LLM 配置开启“失败时回退到 Google”且已配置 Google Key 时存在（R16.12）。
    public let fallback: (any TranslationProvider)?
    public let policy: BatchPolicy

    public init(profileID: UUID, provider: any TranslationProvider, fallback: (any TranslationProvider)? = nil, policy: BatchPolicy) {
        self.profileID = profileID
        self.provider = provider
        self.fallback = fallback
        self.policy = policy
    }
}

public protocol ProviderResolving: Sendable {
    func resolve(_ profileID: UUID?) async -> ResolvedProvider?
}

/// 翻译服务：缓存、批量合并、同文本去重、并发限制、重试和回退（R8.4–R8.6、R16.7、R16.12）。
public actor TranslationService: TranslationServicing {
    private struct BatchKey: Hashable {
        let profileID: UUID
        let source: String?
        let target: String
        let fingerprint: String
        /// 开关不同的请求提示词不同，不合并（C2.7）
        let classifiesLines: Bool
    }

    private struct Batch {
        let id = UUID()
        let resolved: ResolvedProvider
        let source: Language?
        let target: Language
        var context: [ContextPair]
        var appName: String
        let classifiesLines: Bool
        var keys: [TranslationCacheKey] = []
    }

    private let resolver: any ProviderResolving
    private let sleeper: any Sleeper
    private let retryDelays: [Duration]
    private let logger = Logger(subsystem: AppIdentity.subsystem, category: "translation")

    private var cache: TranslationCache
    private var batches: [BatchKey: Batch] = [:]
    /// 已排队或已发出、尚未返回的文本，以及等待它的调用方（同文本并发请求合并）。
    private var waiters: [TranslationCacheKey: [CheckedContinuation<TranslationState, Never>]] = [:]
    private var semaphores: [UUID: AsyncSemaphore] = [:]

    public init(
        resolver: any ProviderResolving,
        sleeper: any Sleeper = TaskSleeper(),
        cacheCapacity: Int = 5000,
        retryDelays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2)]
    ) {
        self.resolver = resolver
        self.sleeper = sleeper
        self.cache = TranslationCache(capacity: cacheCapacity)
        self.retryDelays = retryDelays
    }

    public func clearCache() {
        cache.removeAll()
    }

    public func translate(_ texts: [String], options: TranslationOptions) async -> [TranslationState] {
        guard !texts.isEmpty else { return [] }
        guard let resolved = await resolver.resolve(options.profileID) else {
            return texts.map { _ in .unavailable("没有可用的翻译配置") }
        }
        return await withTaskGroup(of: (Int, TranslationState).self) { group in
            for (index, text) in texts.enumerated() {
                group.addTask { (index, await self.translateOne(text, resolved: resolved, options: options)) }
            }
            var results = [TranslationState](repeating: .pending, count: texts.count)
            for await (index, state) in group { results[index] = state }
            return results
        }
    }

    private func translateOne(_ text: String, resolved: ResolvedProvider, options: TranslationOptions) async -> TranslationState {
        guard !text.isEmpty else { return .done("") }
        let key = TranslationCacheKey(
            text: text, source: options.source, target: options.target,
            fingerprint: resolved.provider.fingerprint, classifiesLines: options.classifiesLines
        )
        if let hit = cache.value(for: key) {
            return hit.state
        }
        return await withCheckedContinuation { continuation in
            if waiters[key] != nil {
                waiters[key]?.append(continuation) // 同一文本已在排队或请求中
            } else {
                waiters[key] = [continuation]
                enqueue(key, resolved: resolved, options: options)
            }
        }
    }

    private func enqueue(_ key: TranslationCacheKey, resolved: ResolvedProvider, options: TranslationOptions) {
        let batchKey = BatchKey(
            profileID: resolved.profileID, source: key.source, target: key.target,
            fingerprint: key.fingerprint, classifiesLines: key.classifiesLines
        )
        let isNew = batches[batchKey] == nil
        var batch = batches[batchKey] ?? Batch(
            resolved: resolved, source: options.source, target: options.target,
            context: options.context, appName: options.appName, classifiesLines: options.classifiesLines
        )
        batch.keys.append(key)
        if batch.context.isEmpty { batch.context = options.context }
        if batch.appName.isEmpty { batch.appName = options.appName }
        batches[batchKey] = batch

        if batch.keys.count >= resolved.policy.maxBatchSize {
            flush(batchKey, id: batch.id)
        } else if isNew {
            let id = batch.id
            let window = resolved.policy.window
            let sleeper = self.sleeper
            Task { // 继承 actor 隔离
                try? await sleeper.sleep(for: window)
                self.flush(batchKey, id: id)
            }
        }
    }

    private func flush(_ batchKey: BatchKey, id: UUID) {
        // 合并窗口到期时，同一 key 下可能已经是一个新的批次，只发送对应 id 的批次
        guard let batch = batches[batchKey], batch.id == id else { return }
        batches.removeValue(forKey: batchKey)
        Task { await self.send(batch) }
    }

    private func semaphore(for resolved: ResolvedProvider) -> AsyncSemaphore {
        if let existing = semaphores[resolved.profileID] { return existing }
        let created = AsyncSemaphore(limit: resolved.policy.maxConcurrentRequests)
        semaphores[resolved.profileID] = created
        return created
    }

    private func send(_ batch: Batch) async {
        let texts = batch.keys.map(\.text)
        let request = TranslationRequest(
            texts: texts, source: batch.source, target: batch.target,
            context: batch.context, appName: batch.appName, classifiesLines: batch.classifiesLines
        )
        let provider = batch.resolved.provider
        let results = await semaphore(for: batch.resolved).withPermit {
            await self.performWithRetry(provider, request)
        }

        var states = [TranslationState](repeating: .pending, count: texts.count)
        var failedIndices: [Int] = []
        for (index, result) in results.enumerated() {
            switch result {
            case let .success(output):
                cache.insert(output, for: batch.keys[index])
                states[index] = output.state
            case let .failure(.notConfigured(reason)):
                states[index] = .unavailable(reason)
            case let .failure(error):
                states[index] = .failed(error.localizedDescription)
                failedIndices.append(index)
            }
        }

        // 回退到 Google（R16.12）。回退结果不写入缓存，避免以后一直使用回退译文
        if let fallback = batch.resolved.fallback, !failedIndices.isEmpty {
            let fallbackRequest = TranslationRequest(
                texts: failedIndices.map { texts[$0] }, source: batch.source, target: batch.target, appName: batch.appName
            )
            let fallbackResults = await performWithRetry(fallback, fallbackRequest)
            for (offset, result) in fallbackResults.enumerated() {
                if case let .success(output) = result, let translated = output.text {
                    states[failedIndices[offset]] = .done(translated, fallback: true)
                }
            }
        }

        for (index, key) in batch.keys.enumerated() {
            for continuation in waiters.removeValue(forKey: key) ?? [] {
                continuation.resume(returning: states[index])
            }
        }
    }

    /// 可重试错误按 0.5s / 1s / 2s 退避，最多重试 3 次（R8.6）。
    private func performWithRetry(_ provider: any TranslationProvider, _ request: TranslationRequest) async -> [Result<TranslationOutput, TranslationError>] {
        var attempt = 0
        while true {
            do {
                let results = try await provider.translate(request)
                guard results.count == request.texts.count else {
                    return request.texts.map { _ in .failure(.invalidResponse("返回条数与请求不一致")) }
                }
                return results
            } catch let error as TranslationError {
                if error.isRetryable, attempt < retryDelays.count {
                    logger.info("Translation failed, retrying (\(attempt + 1, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                    try? await sleeper.sleep(for: retryDelays[attempt])
                    attempt += 1
                    continue
                }
                return request.texts.map { _ in .failure(error) }
            } catch {
                return request.texts.map { _ in .failure(.network(error.localizedDescription)) }
            }
        }
    }
}
