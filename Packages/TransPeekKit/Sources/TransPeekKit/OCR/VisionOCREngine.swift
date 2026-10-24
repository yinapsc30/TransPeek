import CoreGraphics
import CoreText
import Foundation
import Vision

/// 基于 Apple Vision 的 OCR 引擎（R6.1、R6.2）。
public struct VisionOCREngine: OCREngine {
    public var usesLanguageCorrection: Bool

    public init(usesLanguageCorrection: Bool = true) {
        self.usesLanguageCorrection = usesLanguageCorrection
    }

    public func recognize(_ image: CGImage, languages: [String]?) async throws -> [OCRFragment] {
        let usesLanguageCorrection = self.usesLanguageCorrection
        // Vision 的 perform 是同步阻塞调用，放到后台队列执行，避免占用 Swift 并发线程池
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = usesLanguageCorrection
                    if let languages, !languages.isEmpty {
                        request.recognitionLanguages = languages
                    } else {
                        request.automaticallyDetectsLanguage = true
                    }
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                    let fragments = (request.results ?? []).compactMap { observation -> OCRFragment? in
                        guard let candidate = observation.topCandidates(1).first else { return nil }
                        return OCRFragment(
                            text: candidate.string,
                            confidence: candidate.confidence,
                            box: Self.topLeftBox(observation.boundingBox)
                        )
                    }
                    continuation.resume(returning: fragments)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Vision 的归一化坐标原点在左下角，转换为左上角原点。
    static func topLeftBox(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    /// 预热：用一张小的示例图识别一次，让系统提前加载识别模型（R14.5）。
    ///
    /// 实测（macOS 27，Apple 芯片）：每个新编译或新安装的版本，第一次调用 accurate 识别约需 27–30 秒；
    /// 之后新进程的第一次调用约 100–230ms，同一进程内约 60–90ms。
    public func warmUp(languages: [String]?) async {
        guard let image = Self.sampleImage() else { return }
        _ = try? await recognize(image, languages: languages)
    }

    /// 画有几个单词的灰度图。只有空白时识别器可能跳过模型加载，所以画上文字。
    static func sampleImage() -> CGImage? {
        let width = 320, height = 48
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: true] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, "TransPeek warm up 123" as CFString, attributes))
        context.setFillColor(gray: 0, alpha: 1)
        context.textPosition = CGPoint(x: 8, y: 14)
        CTLineDraw(line, context)
        return context.makeImage()
    }
}
