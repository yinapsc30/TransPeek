import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import TransPeekKit

/// 一个 OCR 样例场景：`Fixtures/ocr/<场景名>/image.png` + `expected.json`（design.md「集成测试」）。
struct OCRScene: CustomTestStringConvertible, Sendable {
    struct Expected: Decodable, Sendable {
        /// photo（手机拍屏）或 capture（真实窗口截图）
        var source: String
        var language: String?
        /// 必须出现在某一行中的文本（忽略大小写）
        var mustContain: [String]
        /// 每组文本必须出现在同一行中，用于检查行组装
        var sameLine: [[String]]?
        /// mustContain 允许的最低相似度，默认 1.0（精确子串）
        var minSimilarity: Double?
        var notes: String?
    }

    let name: String
    let directory: URL

    var testDescription: String { name }

    static func all() -> [OCRScene] {
        guard let root = Bundle.module.url(forResource: "Fixtures/ocr", withExtension: nil),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path)
        else { return [] }
        return names.sorted()
            .map { OCRScene(name: $0, directory: root.appendingPathComponent($0)) }
            .filter { FileManager.default.fileExists(atPath: $0.directory.appendingPathComponent("expected.json").path) }
    }

    /// 本地是否有某个场景。含他人信息的真实截图不提交到仓库，从仓库检出时没有这些场景，相关测试跳过（design.md「集成测试」）。
    static func exists(_ name: String) -> Bool {
        all().contains { $0.name == name }
    }

    func load() throws -> (CGImage, Expected) {
        let imageURL = directory.appendingPathComponent("image.png")
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw CocoaError(.fileReadCorruptFile) }
        let data = try Data(contentsOf: directory.appendingPathComponent("expected.json"))
        return (image, try JSONDecoder().decode(Expected.self, from: data))
    }
}

/// 汇总各场景结果，测试结束时输出。
actor OCRReport {
    static let shared = OCRReport()
    private var rows: [String] = []

    func add(_ row: String) {
        rows.append(row)
        print("OCR 样例 | \(row)")
    }
}

@Suite("OCR 样例库", .enabled(if: !OCRScene.all().isEmpty, "没有本地样例截图（不随仓库提交）"))
struct OCRFixtureTests {
    @Test("本地样例的 expected.json 都能读取")
    func scenesLoad() throws {
        for scene in OCRScene.all() { _ = try scene.load() }
    }

    @Test("识别结果包含期望文本", arguments: OCRScene.all())
    func recognize(scene: OCRScene) async throws {
        let (image, expected) = try scene.load()
        let engine = VisionOCREngine()
        let languages = expected.language.map { [$0] }

        _ = try await engine.recognize(image, languages: languages) // 预热，首次调用包含模型加载
        let start = ContinuousClock.now
        let fragments = try await engine.recognize(image, languages: languages)
        let elapsed = ContinuousClock.now - start

        let lines = LineAssembler().assemble(fragments).map(\.text)
        let dump = lines.enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let threshold = expected.minSimilarity ?? 1.0

        var failures: [String] = []
        for text in expected.mustContain where !Self.lines(lines, contain: text, threshold: threshold) {
            failures.append("缺少：\(text)")
        }
        for group in expected.sameLine ?? [] {
            let found = lines.contains { line in group.allSatisfy { line.localizedCaseInsensitiveContains($0) } }
            if !found { failures.append("不在同一行：\(group.joined(separator: " + "))") }
        }

        let millis = Int((elapsed.seconds * 1000).rounded())
        await OCRReport.shared.add("\(scene.name) [\(expected.source)] \(image.width)x\(image.height) \(millis)ms \(failures.isEmpty ? "通过" : "失败")")
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))\n实际识别出的行：\n\(dump)")
    }

    /// 某一行包含 `text`（忽略大小写），或某一行中有与 `text` 等长的片段相似度达到阈值。
    static func lines(_ lines: [String], contain text: String, threshold: Double) -> Bool {
        if lines.contains(where: { $0.localizedCaseInsensitiveContains(text) }) { return true }
        guard threshold < 1 else { return false }
        let target = Array(text)
        return lines.contains { line in
            let chars = Array(line)
            guard chars.count >= target.count else { return Similarity.ratio(line, text) >= threshold }
            // 滑动窗口比较等长片段（允许窗口长度上下浮动 10%）
            let slack = max(1, target.count / 10)
            for length in max(1, target.count - slack)...min(chars.count, target.count + slack) {
                for start in 0...(chars.count - length) {
                    if Similarity.ratio(String(chars[start..<(start + length)]), text) >= threshold { return true }
                }
            }
            return false
        }
    }
}

@Suite("VisionOCREngine")
struct VisionOCREngineTests {
    @Test("Vision 左下原点坐标转换为左上原点")
    func coordinateConversion() {
        let box = VisionOCREngine.topLeftBox(CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.2))
        #expect(abs(box.minY - 0.1) < 1e-9)
        #expect(box.minX == 0.1 && box.width == 0.5 && box.height == 0.2)
    }

    @Test("ThrottledOCREngine 限制并发数")
    func throttling() async throws {
        let probe = ConcurrencyProbe()
        let engine = ThrottledOCREngine(base: SlowEngine(probe: probe), limit: 2)
        let image = try #require(makeSolidImage(width: 4, height: 4, gray: 0))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask { _ = try await engine.recognize(image, languages: nil) }
            }
            try await group.waitForAll()
        }
        #expect(await probe.peak == 2)
    }
}

actor ConcurrencyProbe {
    private(set) var current = 0
    private(set) var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}

struct SlowEngine: OCREngine {
    let probe: ConcurrencyProbe
    func recognize(_ image: CGImage, languages: [String]?) async throws -> [OCRFragment] {
        await probe.enter()
        try await Task.sleep(for: .milliseconds(30))
        await probe.leave()
        return []
    }
}

/// 生成纯色灰度图。
func makeSolidImage(width: Int, height: Int, gray: UInt8) -> CGImage? {
    makeImage(width: width, height: height) { _, _ in gray }
}

/// 按像素函数生成灰度图。
func makeImage(width: Int, height: Int, pixel: (Int, Int) -> UInt8) -> CGImage? {
    var bytes = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width { bytes[y * width + x] = pixel(x, y) }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )
}
