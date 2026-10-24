import Foundation

/// 翻译缓存键：（归一化原文、源语言、目标语言、翻译配置指纹）。上下文不参与（R8.4，design.md 已确认第 4 条）。
public struct TranslationCacheKey: Hashable, Sendable {
    public let text: String
    public let source: String?
    public let target: String
    public let fingerprint: String
    /// 开启和关闭智能整理时的结果分开缓存（ocr-cleanup C2.7）。
    public let classifiesLines: Bool

    public init(text: String, source: Language?, target: Language, fingerprint: String, classifiesLines: Bool = false) {
        self.text = text
        self.source = source?.code
        self.target = target.code
        self.fingerprint = fingerprint
        self.classifiesLines = classifiesLines
    }
}

/// 内存 LRU 缓存。
public struct TranslationCache: Sendable {
    public let capacity: Int
    private var storage: [TranslationCacheKey: (value: TranslationOutput, tick: UInt64)] = [:]
    private var tick: UInt64 = 0

    public init(capacity: Int = 5000) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var count: Int { storage.count }

    public mutating func value(for key: TranslationCacheKey) -> TranslationOutput? {
        guard let entry = storage[key] else { return nil }
        tick += 1
        storage[key] = (entry.value, tick)
        return entry.value
    }

    public mutating func insert(_ value: TranslationOutput, for key: TranslationCacheKey) {
        tick += 1
        storage[key] = (value, tick)
        if storage.count > capacity, let oldest = storage.min(by: { $0.value.tick < $1.value.tick })?.key {
            // 新条目插入远少于读取，O(n) 淘汰在 5000 条规模下可以忽略
            storage.removeValue(forKey: oldest)
        }
    }

    public mutating func removeAll() {
        storage.removeAll()
    }
}
