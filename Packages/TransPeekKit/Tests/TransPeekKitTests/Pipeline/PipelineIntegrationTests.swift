import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import TransPeekKit

/// 用真实的 Vision OCR 和样例截图跑完整流水线：裁剪 → 变化检测 → OCR → 行组装 → 忽略规则 → 聊天增量 → 翻译。
@Suite("流水线集成（Vision + 样例截图）", .enabled(if: OCRScene.exists("maple-trade-chat"), "没有本地样例截图（不随仓库提交）"))
struct PipelineIntegrationTests {
    private func loadFixture(_ scene: String) throws -> CGImage {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/ocr/\(scene)/image", withExtension: "png"))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    @Test("聊天截图：识别出交易消息，频道徽章被忽略规则移除，画面不变时不重复追加")
    func chatScreenshot() async throws {
        let image = try loadFixture("maple-trade-chat")
        // 只框选聊天内容区域（去掉底部的频道标签栏）
        let region = Region(
            name: "交易频道", rect: CGRect(x: 0, y: 0, width: 0.9, height: 0.68), mode: .chat,
            sourceLanguage: .english, targetLanguage: .simplifiedChinese,
            // 徽章是大写 CH + O/0 + 1~2 个字符；H 必须大写，避免误删 "Choco" 这类普通单词
            ignorePatterns: [#"\b[cC]H[O0]\w{1,2}\b"#]
        )
        let translator = EchoTranslator()
        let sink = EventSink()
        let pipeline = RegionPipeline(
            configuration: PipelineConfiguration(region: region, appName: "MapleStory"),
            ocr: VisionOCREngine(), translator: translator, output: sink.output
        )

        for index in 0..<6 { // 1.5 秒同一画面
            await pipeline.submit(windowImage: image, at: Double(index) * 0.25)
            await pipeline.waitUntilIdle()
        }

        #expect(await pipeline.recognitionCount == 1)
        let lines = sink.originals
        let dump = lines.joined(separator: "\n")
        #expect(lines.contains { $0.contains("S> Choco Candy Cookie 180K") }, "\(dump)")
        // 手机拍屏的裁剪图上 "Black" 偶尔被识别为 "Plack"，只检查稳定的部分
        #expect(lines.contains { $0.contains("Dollish Pink 1:1") }, "\(dump)")
        #expect(!lines.contains { $0.contains("All") && $0.count < 6 }, "底部频道标签不在框选范围内：\(dump)")
        #expect(!lines.contains { $0.range(of: #"\bCH[O0]\d"#, options: .regularExpression) != nil }, "徽章应被移除：\(dump)")
        #expect(sink.updates.count == lines.count)
        print("集成测试识别结果：\n\(dump)")
    }
}
