import CoreGraphics
import Foundation

/// 用于变化检测的灰度缩略图。
public struct GrayThumbnail: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// 把图像缩放到指定宽度（保持比例）的灰度图。
    public init?(image: CGImage, width targetWidth: Int = 128) {
        guard image.width > 0, image.height > 0 else { return nil }
        let width = min(targetWidth, image.width)
        let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, pixels: pixels)
    }

    /// 平均绝对差（0...255）。尺寸不同时返回 `nil`，调用方应视为发生变化。
    public func meanAbsoluteDifference(to other: GrayThumbnail) -> Double? {
        guard width == other.width, height == other.height, !pixels.isEmpty else { return nil }
        var total = 0
        for index in pixels.indices {
            total += abs(Int(pixels[index]) - Int(other.pixels[index]))
        }
        return Double(total) / Double(pixels.count)
    }
}

/// 判断区域画面是否发生变化（R5.3）。
public struct ChangeDetector: Sendable {
    /// 平均绝对差超过该值视为变化。
    public var threshold: Double

    public init(threshold: Double = 2.0) {
        self.threshold = threshold
    }

    public func difference(_ a: GrayThumbnail?, _ b: GrayThumbnail) -> Double {
        guard let a else { return .infinity }
        return a.meanAbsoluteDifference(to: b) ?? .infinity
    }

    public func isChanged(from baseline: GrayThumbnail?, to current: GrayThumbnail) -> Bool {
        difference(baseline, current) > threshold
    }
}
