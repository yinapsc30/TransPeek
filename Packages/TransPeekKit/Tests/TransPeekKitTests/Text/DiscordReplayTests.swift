import CoreGraphics
import Testing
@testable import TransPeekKit

/// 用户试用时在 Discord（Chrome）聊天中实际得到的两次识别结果（根据面板截图还原）。
@Suite("实测回放：Discord 聊天")
struct DiscordReplayTests {
    static let first = [
        "Black Kottyn NotCreative",
        "KayaBread : u indian? or malay",
        "Haka OGLUE 14:39",
        "isnt it kinda hard to move around with low speed ._.",
        "@NotCreative no reward today? o.o she took my maple leafs and i got nothing (Eita)",
        "Archereon - Merc 14:40",
        "I got a permit today",
    ]

    /// 第二次：中间多识别出一行回复引用（Maple Lea…），名字行的符号有差异，底部新增几行。
    static let second = [
        "KayaBread : u indian? or malay",
        "Maple Lea: Su has been lost re",
        "Haka OGLUE 14:39",
        "isnt it kinda hard to move around with low speed ._.",
        "@NotCreative no reward today? o.o she took my maple leafs and i got nothing (Eita)",
        "Archereon Merc 14:40",
        "I got a permit today",
        "For shop",
        "Sanktas /idle 14:40",
    ]

    @Test("中间多出一行时仍能对齐，只追加底部的新行，不插入遗漏标记")
    func insertedLineInMiddle() {
        let diff = LineDiffer().diff(previous: Self.first, current: Self.second)
        #expect(diff == ChatDiff(newLines: ["For shop", "Sanktas /idle 14:40"], possibleGap: false))
    }

    @Test("中间少识别一行时也不重复")
    func missingLineInMiddle() {
        let diff = LineDiffer().diff(previous: Self.second, current: Array(Self.second.dropFirst(2)) + ["Please send offers"])
        #expect(diff == ChatDiff(newLines: ["Please send offers"], possibleGap: false))
        let removedMiddle = Self.second.enumerated().filter { $0.offset != 3 }.map(\.element)
        #expect(LineDiffer().diff(previous: Self.second, current: removedMiddle) == .none)
    }

    @Test("只有很短的行能匹配时不认为有重叠")
    func shortMatchIsNotReliable() {
        let diff = LineDiffer().diff(previous: ["alpha says hi", "gg"], current: ["gg", "xray wts bow"])
        #expect(diff == ChatDiff(newLines: ["gg", "xray wts bow"], possibleGap: true))
    }

    @Test("重复内容：新进来的同样消息不会被吞掉")
    func repeatedContentTie() {
        let diff = LineDiffer().diff(previous: ["need heal please", "omw now buddy"], current: ["omw now buddy", "need heal please"])
        #expect(diff.newLines == ["need heal please"])
    }

    @Test("贴着区域上下边缘的半截行被丢弃")
    func clippedLines() {
        let lines = [
            OCRLine(text: "Black Kottyn NotCreative", box: CGRect(x: 0.1, y: 0.0, width: 0.5, height: 0.03)),  // 上边缘被切
            OCRLine(text: "KayaBread : u indian? or malay", box: CGRect(x: 0.1, y: 0.05, width: 0.6, height: 0.04)),
            OCRLine(text: "Please s", box: CGRect(x: 0.1, y: 0.975, width: 0.2, height: 0.025)),               // 下边缘被切
        ]
        let kept = RegionPipeline.droppingClippedLines(lines, imageHeight: 400)
        #expect(kept.map(\.text) == ["KayaBread : u indian? or malay"])
    }
}
