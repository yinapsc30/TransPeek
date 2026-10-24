import CoreGraphics
import Foundation

/// OCR 识别出的一个文本片段。
public struct OCRFragment: Sendable, Equatable {
    public let text: String
    public let confidence: Float
    /// 归一化坐标，原点左上。
    public let box: CGRect

    public init(text: String, confidence: Float, box: CGRect) {
        self.text = text
        self.confidence = confidence
        self.box = box
    }
}

/// 可替换的 OCR 引擎接口（R6.6）。
public protocol OCREngine: Sendable {
    /// - Parameter languages: 识别语言（Vision 代码），`nil` 表示自动检测。
    func recognize(_ image: CGImage, languages: [String]?) async throws -> [OCRFragment]
}

/// 限制全局并发的 OCR 包装（design.md「并发模型」：最多 2 个并发 Vision 请求）。
public struct ThrottledOCREngine: OCREngine {
    private let base: any OCREngine
    private let semaphore: AsyncSemaphore

    public init(base: any OCREngine, limit: Int = 2) {
        self.base = base
        self.semaphore = AsyncSemaphore(limit: limit)
    }

    public func recognize(_ image: CGImage, languages: [String]?) async throws -> [OCRFragment] {
        let base = self.base
        return try await semaphore.withPermit {
            try await base.recognize(image, languages: languages)
        }
    }
}
