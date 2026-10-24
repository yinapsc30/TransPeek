import CoreGraphics
import Testing
@testable import TransPeekKit

@Suite("Similarity")
struct SimilarityTests {
    @Test("边界值")
    func boundaries() {
        #expect(Similarity.ratio("", "") == 1)
        #expect(Similarity.ratio("abc", "") == 0)
        #expect(Similarity.ratio("abc", "abc") == 1)
        #expect(Similarity.ratio("ABC", "abc") == 1)
        #expect(Similarity.ratio("abc", "xyz") == 0)
        #expect(Similarity.levenshtein(Array("kitten"), Array("sitting")) == 3)
    }

    @Test("OCR 抖动视为同一行，不同内容不视为同一行")
    func ocrJitter() {
        // 实测：同一行两次识别结果的细微差异
        #expect(Similarity.isSame("GUTSs : S> Choco Candy Cookie 180K", "GUTS : S> Choco Candy Cookie 180k"))
        #expect(Similarity.isSame("Kapoot : T> Dollish Pink 1:1 Black Suit Pants", "Kapoot : T> Dollish Pink 1:1 BlackSuit Pants"))
        #expect(!Similarity.isSame("S> Choco Candy Cookie 180K", "B> Level 50 Bow and OA 60%"))
        #expect(!Similarity.isSame("gg", "ty"))
    }
}

@Suite("TextNormalizer 与忽略规则")
struct TextNormalizerTests {
    @Test("折叠空白、统一全角空格、去除首尾孤立符号", arguments: [
        ("  hello   world  ", "hello world"),
        ("你好\u{3000}世界", "你好 世界"),
        ("| Jammies obtained |", "Jammies obtained"),
        ("• • item", "item"),
        ("a | b", "a | b"),          // 中间的符号保留
        ("[Gephart] S> +3", "[Gephart] S> +3"),
        ("||", ""),
    ])
    func normalize(input: String, expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    @Test("忽略规则移除频道徽章噪声")
    func ignoreRules() {
        let rules = IgnoreRules(patterns: [#"\bCH[O0]\w{1,2}\b"#])
        #expect(rules.apply(to: "Glacor CHO6 : B> Level 50 Bow") == "Glacor : B> Level 50 Bow")
        #expect(rules.apply(to: "CHO1") == "")
    }

    @Test("无效正则被跳过并记录")
    func invalidPattern() {
        let rules = IgnoreRules(patterns: ["(unclosed", "", "ok"])
        #expect(rules.invalidPatterns == ["(unclosed"])
        #expect(!IgnoreRules.isValid("(unclosed"))
        #expect(IgnoreRules.isValid(#"\d+"#))
        #expect(rules.apply(to: "ok go") == "go")
    }
}

@Suite("LineAssembler")
struct LineAssemblerTests {
    private func fragment(_ text: String, _ confidence: Float = 1, x: CGFloat, y: CGFloat, w: CGFloat = 0.2, h: CGFloat = 0.1) -> OCRFragment {
        OCRFragment(text: text, confidence: confidence, box: CGRect(x: x, y: y, width: w, height: h))
    }

    @Test("名字 + 徽章 + 消息三段合成一行（实测场景）")
    func mergesSplitChatLine() {
        // 与 Vision 在聊天截图上的实测结果一致：同一行被拆成三段，且高度、位置略有差异
        let fragments = [
            fragment(": S> Choco Candy Cookie 180K", x: 0.28, y: 0.30, w: 0.5, h: 0.10),
            fragment("GUTSs", 0.3, x: 0.02, y: 0.31, w: 0.08, h: 0.09),
            fragment("CHO1", 0.5, x: 0.11, y: 0.305, w: 0.06, h: 0.08),
        ]
        let lines = LineAssembler().assemble(fragments)
        #expect(lines.map(\.text) == ["GUTSs CHO1 : S> Choco Candy Cookie 180K"])

        let cleaned = LineAssembler().assemble(fragments, ignoring: IgnoreRules(patterns: [#"\bCH[O0]\w{1,2}\b"#]))
        #expect(cleaned.map(\.text) == ["GUTSs : S> Choco Candy Cookie 180K"])
    }

    @Test("多行按从上到下排序，行内按从左到右排序")
    func ordersLines() {
        let fragments = [
            fragment("third", x: 0.1, y: 0.7),
            fragment("first-b", x: 0.5, y: 0.1),
            fragment("second", x: 0.1, y: 0.4),
            fragment("first-a", x: 0.1, y: 0.12),
        ]
        #expect(LineAssembler().assemble(fragments).map(\.text) == ["first-a first-b", "second", "third"])
    }

    @Test("丢弃低于阈值的片段，阈值本身保留")
    func confidenceThreshold() {
        let fragments = [
            fragment("keep", 0.3, x: 0.1, y: 0.1),
            fragment("drop", 0.29, x: 0.5, y: 0.1),
            fragment("   ", 1, x: 0.1, y: 0.5),
        ]
        #expect(LineAssembler(confidenceThreshold: 0.3).assemble(fragments).map(\.text) == ["keep"])
    }

    @Test("相邻但不重叠的两行不会合并")
    func adjacentLinesStaySeparate() {
        let fragments = [
            fragment("line one", x: 0.1, y: 0.10, h: 0.1),
            fragment("line two", x: 0.1, y: 0.17, h: 0.1), // 重叠 0.03 < 0.05
        ]
        #expect(LineAssembler().assemble(fragments).count == 2)
    }

    @Test("行的外接矩形覆盖所有片段")
    func unionBox() {
        let lines = LineAssembler().assemble([fragment("a", x: 0.1, y: 0.1), fragment("b", x: 0.6, y: 0.12)])
        let box = try! #require(lines.first?.box)
        let expected = CGRect(x: 0.1, y: 0.1, width: 0.7, height: 0.12)
        #expect(abs(box.minX - expected.minX) < 1e-9 && abs(box.minY - expected.minY) < 1e-9)
        #expect(abs(box.maxX - expected.maxX) < 1e-9 && abs(box.maxY - expected.maxY) < 1e-9)
    }
}

@Suite("LineDiffer")
struct LineDifferTests {
    let differ = LineDiffer()

    @Test("首次识别：全部是新行")
    func firstRecognition() {
        #expect(differ.diff(previous: [], current: ["a msg", "b msg"]) == ChatDiff(newLines: ["a msg", "b msg"], possibleGap: false))
        #expect(differ.diff(previous: ["a msg"], current: []) == .none)
    }

    @Test("聊天向上滚动：只追加底部新行")
    func scrollAppend() {
        let previous = ["alpha says hi", "bravo sells sword", "charlie buys pot", "delta lfg"]
        let current = ["charlie buys pot", "delta lfg", "echo wts helm", "foxtrot gg"]
        #expect(differ.diff(previous: previous, current: current).newLines == ["echo wts helm", "foxtrot gg"])
    }

    @Test("区域未满时新消息追加在底部")
    func appendWithoutScroll() {
        #expect(differ.diff(previous: ["alpha hi"], current: ["alpha hi", "bravo yo"]).newLines == ["bravo yo"])
    }

    @Test("内容没有变化：不产生新条目")
    func unchanged() {
        let lines = ["alpha says hi", "bravo sells sword", "charlie buys pot"]
        #expect(differ.diff(previous: lines, current: lines) == .none)
    }

    @Test("用户向上翻看历史：不产生新条目")
    func scrollBack() {
        let previous = ["charlie buys pot", "delta lfg", "echo wts helm", "foxtrot gg"]
        let current = ["alpha says hi", "bravo sells sword", "charlie buys pot", "delta lfg"]
        #expect(differ.diff(previous: previous, current: current) == .none)
    }

    @Test("完全没有重叠：输出遗漏标记和全部行")
    func noOverlap() {
        let diff = differ.diff(previous: ["alpha says hi", "bravo sells sword"], current: ["xray wts bow", "yankee lfg party"])
        #expect(diff == ChatDiff(newLines: ["xray wts bow", "yankee lfg party"], possibleGap: true))
    }

    @Test("OCR 抖动下仍能对齐")
    func fuzzyAlignment() {
        let previous = ["GUTSs : S> Choco Candy Cookie 180K", "Kristen : [Gephart] S> +3 M 40 dagger 110k"]
        let current = ["GUTS : S> Choco Candy Cookie 180k", "Kristen : [Gephartj S>+3 M 40 dagger 110k", "Kapoot : T> Dollish Pink"]
        #expect(differ.diff(previous: previous, current: current).newLines == ["Kapoot : T> Dollish Pink"])
    }

    @Test("较长重叠中个别行识别差异较大时仍能对齐")
    func toleratesOneBadLineInLongOverlap() {
        let previous = ["line one here", "line two here", "line three here", "line four here", "line five here"]
        let current = ["line two here", "l1ne thr33 h3r3 ???", "line four here", "line five here", "line six here"]
        #expect(differ.diff(previous: previous, current: current).newLines == ["line six here"])
    }

    @Test("真实的连续重复消息不会被误删")
    func repeatedMessages() {
        // 两条 gg 是新消息：上一帧最后一行是 "wp all"
        let diff = differ.diff(previous: ["boss down", "wp all"], current: ["boss down", "wp all", "gg", "gg"])
        #expect(diff.newLines == ["gg", "gg"])
    }

    @Test("对话模式：相似文本不替换，新文本替换")
    func dialogComparator() {
        #expect(DialogComparator.shouldReplace(current: nil, with: "Hello traveler"))
        #expect(!DialogComparator.shouldReplace(current: "Hello traveler", with: "Hello travelor"))
        #expect(DialogComparator.shouldReplace(current: "Hello traveler", with: "The bridge is out."))
        #expect(!DialogComparator.shouldReplace(current: "Hello traveler", with: ""))
    }
}
