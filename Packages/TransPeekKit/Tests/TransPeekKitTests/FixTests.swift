import CoreGraphics
import Foundation
import Testing
@testable import TransPeekKit

@Suite("中文不翻译（R8.9）")
struct ChineseSkipTests {
    @Test("中文判断", arguments: [
        ("交易 S> 巧克力饼干 180K", true),
        ("需要治疗", true),
        ("繁體中文測試", true),
        ("S> Choco Candy Cookie 180K", false),
        ("こんにちは世界", false),          // 日文（含假名和汉字）
        ("東京へ行きます", false),
        ("안녕하세요 世界", false),         // 韩文
        ("", false),
    ])
    func detect(text: String, expected: Bool) {
        #expect(TextScript.containsChinese(text) == expected)
    }

    @Test("目标语言为中文时，含中文的行直接显示原文，不发送给翻译服务")
    func pipelineSkipsChinese() async {
        let ocr = ScriptedOCR([["need heal", "收到，马上来", "gg"]])
        let translator = EchoTranslator()
        let sink = EventSink()
        let region = Region(name: "r", rect: CGRect(x: 0, y: 0, width: 1, height: 1), mode: .once, targetLanguage: .simplifiedChinese)
        let pipeline = RegionPipeline(configuration: PipelineConfiguration(region: region, appName: "Game"), ocr: ocr, translator: translator, output: sink.output)
        await pipeline.recognizeNow(windowImage: makeSolidImage(width: 200, height: 100, gray: 50)!)
        await pipeline.waitUntilIdle()

        #expect(await translator.calls.map(\.texts) == [["need heal", "gg"]])
        #expect(sink.updates.contains(.done("收到，马上来")))
        #expect(sink.updates.contains(.done("译:need heal")))
    }

    @Test("目标语言不是中文时，中文照常翻译")
    func nonChineseTarget() async {
        let ocr = ScriptedOCR([["收到"]])
        let translator = EchoTranslator()
        let sink = EventSink()
        let region = Region(name: "r", rect: CGRect(x: 0, y: 0, width: 1, height: 1), mode: .once, targetLanguage: .english)
        let pipeline = RegionPipeline(configuration: PipelineConfiguration(region: region, appName: "Game"), ocr: ocr, translator: translator, output: sink.output)
        await pipeline.recognizeNow(windowImage: makeSolidImage(width: 200, height: 100, gray: 50)!)
        await pipeline.waitUntilIdle()
        #expect(await translator.calls.map(\.texts) == [["收到"]])
    }
}

@Suite("贴边外侧放置（R9.2）")
struct DockOutsideFallbackTests {
    let screen = CGRect(x: 0, y: 30, width: 1920, height: 1170)

    @Test("外侧空间不足设定厚度但不少于 200pt 时，缩小厚度放在外侧")
    func shrinkOutside() {
        let window = CGRect(x: 360, y: 200, width: 1300, height: 800) // 右侧只有 260pt
        let layout = DockLayoutCalculator.layout(window: window, edge: .right, thickness: 320, visibleFrame: screen, collapsed: false)
        #expect(layout == DockLayout(frame: CGRect(x: 1660, y: 200, width: 260, height: 800), placement: .outside, edge: .right))
    }

    @Test("所选边放不下时换到对边外侧")
    func oppositeEdge() {
        let window = CGRect(x: 400, y: 200, width: 1420, height: 800) // 右侧 100pt，左侧 400pt
        let layout = DockLayoutCalculator.layout(window: window, edge: .right, thickness: 320, visibleFrame: screen, collapsed: false)
        #expect(layout == DockLayout(frame: CGRect(x: 80, y: 200, width: 320, height: 800), placement: .outside, edge: .left))
    }

    @Test("两侧都放不下时使用内侧（例如铺满屏幕的窗口）")
    func insideWhenBothSidesFull() {
        let window = CGRect(x: 0, y: 30, width: 1707, height: 1170) // 实测：Chrome 窗口，右侧只剩 213pt…
        let full = CGRect(x: 0, y: 30, width: 1920, height: 1170)
        let layout = DockLayoutCalculator.layout(window: full, edge: .right, thickness: 320, visibleFrame: screen, collapsed: false)
        #expect(layout.placement == .inside && layout.edge == .right)
        // …右侧 213pt ≥ 200pt，可以缩小后放在外侧
        let chrome = DockLayoutCalculator.layout(window: window, edge: .right, thickness: 320, visibleFrame: screen, collapsed: false)
        #expect(chrome == DockLayout(frame: CGRect(x: 1707, y: 30, width: 213, height: 1170), placement: .outside, edge: .right))
    }

    @Test("上下贴边时，超出屏幕可用区域的长度被裁掉")
    func clipLength() {
        let window = CGRect(x: -100, y: 200, width: 900, height: 500) // 窗口左侧超出屏幕
        let layout = DockLayoutCalculator.layout(window: window, edge: .bottom, thickness: 150, visibleFrame: screen, collapsed: false)
        #expect(layout == DockLayout(frame: CGRect(x: 0, y: 700, width: 800, height: 150), placement: .outside, edge: .bottom))
    }
}

@Suite("面板调整大小区域（R9.1、R10.1）")
struct PanelResizeZoneTests {
    let size = CGSize(width: 300, height: 400)
    let all = Set(DockEdge.allCases)

    @Test("悬浮模式：四条边和下方两个角")
    func floating() {
        #expect(PanelResizeZones.edges(at: CGPoint(x: 298, y: 200), in: size, allowedEdges: all, allowsCorners: true) == [.right])
        #expect(PanelResizeZones.edges(at: CGPoint(x: 2, y: 200), in: size, allowedEdges: all, allowsCorners: true) == [.left])
        #expect(PanelResizeZones.edges(at: CGPoint(x: 150, y: 2), in: size, allowedEdges: all, allowsCorners: true) == [.top])
        #expect(PanelResizeZones.edges(at: CGPoint(x: 150, y: 398), in: size, allowedEdges: all, allowsCorners: true) == [.bottom])
        #expect(PanelResizeZones.edges(at: CGPoint(x: 292, y: 392), in: size, allowedEdges: all, allowsCorners: true) == [.right, .bottom])
        #expect(PanelResizeZones.edges(at: CGPoint(x: 5, y: 395), in: size, allowedEdges: all, allowsCorners: true) == [.left, .bottom])
        #expect(PanelResizeZones.edges(at: CGPoint(x: 295, y: 3), in: size, allowedEdges: all, allowsCorners: true) == [.right]) // 上方角不作为角
        #expect(PanelResizeZones.edges(at: CGPoint(x: 150, y: 200), in: size, allowedEdges: all, allowsCorners: true) == nil)
    }

    @Test("贴边模式：只有调整厚度的一条边")
    func docked() {
        #expect(PanelResizeZones.edges(at: CGPoint(x: 2, y: 200), in: size, allowedEdges: [.left], allowsCorners: false) == [.left])
        #expect(PanelResizeZones.edges(at: CGPoint(x: 298, y: 200), in: size, allowedEdges: [.left], allowsCorners: false) == nil)
        #expect(PanelResizeZones.edges(at: CGPoint(x: 2, y: 398), in: size, allowedEdges: [.left], allowsCorners: false) == [.left])
    }
}

@Suite("OCR 预热（R14.5）")
struct WarmUpTests {
    @Test("示例图能被识别出文字")
    func sampleImageIsRecognizable() async throws {
        let image = try #require(VisionOCREngine.sampleImage())
        let fragments = try await VisionOCREngine().recognize(image, languages: ["en-US"])
        #expect(fragments.contains { $0.text.localizedCaseInsensitiveContains("warm") })
    }

    @Test("同一语言只预热一次，完成后标记为已预热")
    func warmUpOnce() async {
        let warmUp = OCRWarmUp()
        #expect(await !warmUp.isWarm(languages: ["en-US"]))
        async let a: Void = warmUp.warmUp(languages: ["en-US"])
        async let b: Void = warmUp.warmUp(languages: ["en-US"])
        _ = await (a, b)
        #expect(await warmUp.isWarm(languages: ["en-US"]))
        #expect(await !warmUp.isWarm(languages: nil))
    }
}
