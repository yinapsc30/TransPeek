import Foundation

/// OCR 预热：每种识别语言组合只预热一次，重复调用会等待同一次预热完成（R14.5）。
public actor OCRWarmUp {
    private let engine: VisionOCREngine
    private var tasks: [String: Task<Void, Never>] = [:]

    public init(engine: VisionOCREngine = VisionOCREngine()) {
        self.engine = engine
    }

    private var finished: Set<String> = []

    /// 该语言组合是否已经预热完成。
    public func isWarm(languages: [String]?) -> Bool {
        finished.contains(Self.key(languages))
    }

    /// - Parameter languages: Vision 识别语言，`nil` 表示自动检测。
    public func warmUp(languages: [String]?) async {
        let key = Self.key(languages)
        if let task = tasks[key] {
            await task.value
            return
        }
        let engine = self.engine
        let task = Task(priority: .utility) {
            await engine.warmUp(languages: languages)
        }
        tasks[key] = task
        await task.value
        finished.insert(key)
    }

    private static func key(_ languages: [String]?) -> String {
        languages?.sorted().joined(separator: ",") ?? "auto"
    }
}
