import AppKit
import CoreImage
import CoreMedia
import OSLog
import ScreenCaptureKit
import TransPeekKit

/// 一帧窗口画面。只在内存中流转，不写入磁盘（R5.6）。
struct CapturedFrame: Sendable {
    let image: CGImage
    /// 单调时间（秒）。
    let time: TimeInterval
}

enum CaptureError: LocalizedError {
    case windowNotFound

    var errorDescription: String? {
        switch self {
        case .windowNotFound: "找不到目标窗口，可能已经关闭"
        }
    }
}

/// 按窗口截取画面（design.md「CaptureService」）。
///
/// - 只截取目标窗口本身，被遮挡时仍可截取，TransPeek 的面板不会被截入（R3.7、R5.1）。
/// - 同一窗口的所有持续监听区域共用一个 stream（R5.2）。
@MainActor
final class CaptureService {
    private var streams: [CGWindowID: StreamBox] = [:]
    private let logger = Logger(subsystem: AppIdentity.subsystem, category: "capture")

    var activeWindowIDs: Set<CGWindowID> { Set(streams.keys) }

    /// 开始截取，返回帧序列。消费者处理不过来时只保留最新一帧。
    /// - Parameter onStop: stream 意外停止时调用（主线程）。
    func startStream(window: TrackedWindow, fps: Int, onStop: @escaping @MainActor (Error?) -> Void) async throws -> AsyncStream<CapturedFrame> {
        stopStream(window.windowID)
        guard let scWindow = try await WindowCatalog.scWindow(window.windowID) else { throw CaptureError.windowNotFound }

        let (frames, continuation) = AsyncStream.makeStream(of: CapturedFrame.self, bufferingPolicy: .bufferingNewest(1))
        let configuration = Self.configuration(for: scWindow.frame, fps: fps)
        let box = StreamBox(continuation: continuation, onStop: { error in
            DispatchQueue.main.async { MainActor.assumeIsolated { onStop(error) } }
        })
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: scWindow), configuration: configuration, delegate: box)
        try stream.addStreamOutput(box, type: .screen, sampleHandlerQueue: box.queue)
        box.stream = stream
        streams[window.windowID] = box
        do {
            try await stream.startCapture()
        } catch {
            streams.removeValue(forKey: window.windowID)
            continuation.finish()
            throw error
        }
        logger.info("Capture started at \(fps, privacy: .public) fps")
        return frames
    }

    /// 窗口尺寸或采样频率变化时更新配置。
    func updateStream(_ windowID: CGWindowID, frame: CGRect, fps: Int) {
        guard let stream = streams[windowID]?.stream else { return }
        let configuration = Self.configuration(for: frame, fps: fps)
        Task { [logger] in
            do {
                try await stream.updateConfiguration(configuration)
            } catch {
                logger.error("Failed to update stream: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func stopStream(_ windowID: CGWindowID) {
        guard let box = streams.removeValue(forKey: windowID) else { return }
        box.isStoppingIntentionally = true
        box.continuation.finish()
        if let stream = box.stream {
            Task { try? await stream.stopCapture() }
        }
    }

    func stopAll() {
        for windowID in Array(streams.keys) { stopStream(windowID) }
    }

    /// 单张截图，用于只有“单次”区域时（不开 stream）。
    func screenshot(_ window: TrackedWindow) async throws -> CGImage {
        guard let scWindow = try await WindowCatalog.scWindow(window.windowID) else { throw CaptureError.windowNotFound }
        let configuration = Self.configuration(for: scWindow.frame, fps: 1)
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: scWindow),
            configuration: configuration
        )
    }

    private static func configuration(for frame: CGRect, fps: Int) -> SCStreamConfiguration {
        let scale = ScreenGeometry.backingScale(forCG: frame)
        let configuration = SCStreamConfiguration()
        // 原始分辨率，保证 OCR 清晰度
        configuration.width = max(2, Int((frame.width * scale).rounded()))
        configuration.height = max(2, Int((frame.height * scale).rounded()))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 3
        configuration.capturesAudio = false
        return configuration
    }
}

/// SCStream 的输出和代理，在专用串行队列上接收帧。
private final class StreamBox: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.transpeek.capture", qos: .userInitiated)
    let continuation: AsyncStream<CapturedFrame>.Continuation
    let onStop: @Sendable (Error?) -> Void
    var stream: SCStream?
    var isStoppingIntentionally = false
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(continuation: AsyncStream<CapturedFrame>.Continuation, onStop: @escaping @Sendable (Error?) -> Void) {
        self.continuation = continuation
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusValue) == .complete, // idle 帧表示画面没有变化
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        // 拷贝成独立的 CGImage，尽快归还 stream 的缓冲区
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let image = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        continuation.yield(CapturedFrame(image: image, time: CACurrentMediaTime()))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        continuation.finish()
        guard !isStoppingIntentionally else { return }
        onStop(error)
    }
}
