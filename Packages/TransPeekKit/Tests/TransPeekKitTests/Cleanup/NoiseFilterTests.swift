import Testing
@testable import TransPeekKit

@Suite("NoiseFilter（C1）")
struct NoiseFilterTests {
    let filter = NoiseFilter()

    @Test("名字/时间行（实测数据）", arguments: [
        "Haka OGLUE 14:39",
        "Archereon - Merc 14:40",
        "Sanktas /idle 14:40",
        "Today at 2:39 PM",
        "KayaBread 昨天 下午2:39",
        "张三 14:39:05",
        "[14:39]",
        "#general 9:05",
        "@Mira 10:00 am",
    ])
    func metadata(text: String) {
        #expect(filter.classify(text, detectsMetadata: true)?.role == .metadata)
    }

    @Test("以时间结尾的消息不是名字行", arguments: [
        "meet at 10:30",                 // 第一个词小写
        "[14:39] Rex: gg",               // 时间在开头
        "Rex: see you at 10:30",         // 含冒号
        "Boss spawns at 10:30. Hurry",   // 不以时间结尾
        "We should go now before 10:30", // 词太多
        "Ready? 10:30",                  // 含问号
    ])
    func messages(text: String) {
        #expect(filter.classify(text, detectsMetadata: true)?.role == .message)
    }

    @Test("关闭名字行识别时全部按消息处理")
    func metadataDisabled() {
        #expect(filter.classify("Haka OGLUE 14:39", detectsMetadata: false)?.role == .message)
    }

    @Test("移除界面标签", arguments: [
        ("@NotCreative no reward today (edited)", "@NotCreative no reward today"),
        ("I got a permit today（已编辑）", "I got a permit today"),
        ("今日は (編集済み) 晴れ", "今日は 晴れ"),
        ("안녕 (수정됨)", "안녕"),
        ("(Edited)", nil),
    ])
    func uiLabels(input: String, expected: String?) {
        #expect(filter.classify(input, detectsMetadata: false)?.text == expected)
    }

    @Test("乱码行被丢弃，短消息保留", arguments: [
        ("•", true), ("|| ::", true), ("1:1", true), ("k", true), ("€ 0 •", true), ("@ # 1 2 3 a", true),
        ("gg", false), ("ok", false), ("S> 180K", false), ("好的", false), ("+3 lvl 40 dagger 110k", false),
        ("[14:39] Rex: gg", false), ("1 2 3 4 5 6 7 8 9 ab", true),
    ])
    func garbage(text: String, dropped: Bool) {
        #expect((filter.classify(text, detectsMetadata: true) == nil) == dropped)
    }
}
