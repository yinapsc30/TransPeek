import CoreGraphics
import Foundation
import Testing
@testable import TransPeekKit

@Suite("面板样式（panel-redesign P1、P3.5）")
struct PanelStyleTests {
    @Test("由摆放方式决定样式")
    func fromPlacement() {
        #expect(PanelStyle(placement: .docked(edge: .right, thickness: 300)) == .hud)
        #expect(PanelStyle(placement: .floating(offset: .zero, size: CGSize(width: 300, height: 200))) == .subtitle)
    }

    @Test("背景不透明度：内侧更透明，字幕比 HUD 透明，字幕悬停时加深")
    func opacity() {
        let hud = PanelStyle.hud.backgroundOpacity(0.85, inside: false, hovering: false)
        let inside = PanelStyle.hud.backgroundOpacity(0.85, inside: true, hovering: false)
        let subtitle = PanelStyle.subtitle.backgroundOpacity(0.85, inside: false, hovering: false)
        let hovering = PanelStyle.subtitle.backgroundOpacity(0.85, inside: false, hovering: true)
        #expect(abs(hud - 0.68) < 0.001)
        #expect(abs(inside - 0.60) < 0.001)
        #expect(abs(subtitle - 0.255) < 0.001)
        #expect(abs(hovering - 0.655) < 0.001)
        #expect(subtitle < inside && inside < hud)
        #expect(PanelStyle.subtitle.backgroundOpacity(1, inside: false, hovering: true) <= 0.85)
        // 悬停只影响字幕样式
        #expect(PanelStyle.hud.backgroundOpacity(0.85, inside: false, hovering: true) == hud)
    }
}

@Suite("说话人与显示条目（panel-redesign P5）")
struct DisplayItemTests {
    let region = UUID()

    private func line(_ text: String, _ state: TranslationState = .done("译文")) -> Entry {
        Entry(regionID: region, original: text, translation: state)
    }

    @Test("去掉名字行中的时间和分隔符；只有时间时为空", arguments: [
        ("Kael 21:04", "Kael"),
        ("Kael — Today at 21:04", "Kael"),
        ("Kael 昨天 21:04", "Kael"),
        ("小明 下午 9:04", "小明"),
        ("Mira [9:04 PM]", "Mira"),
        ("Dorn · 21:05", "Dorn"),
        ("Kael", "Kael"),
    ])
    func speaker(_ input: String, _ expected: String) {
        #expect(SpeakerLabel.name(fromMetadata: input) == expected)
    }

    @Test("只有时间的名字行没有说话人")
    func timeOnly() {
        #expect(SpeakerLabel.name(fromMetadata: "21:04") == nil)
        #expect(SpeakerLabel.name(fromMetadata: " [9:04 PM] ") == nil)
    }

    @Test("名字行成为下一条消息的说话人，不单独显示；最新一条只标记最后一条消息")
    func pairing() {
        let a = line("hi"), b = line("yo")
        let items = PanelHistory.displayItems(from: [line("Kael 21:04", .metadata), a, b])
        #expect(items.map(\.id) == [a.id, b.id])
        #expect(items.map(\.speaker) == ["Kael", nil])
        #expect(items.map(\.isLatest) == [false, true])
    }

    @Test("连续名字行取后一条；遗漏标记清空；末尾名字行不显示")
    func edgeCases() {
        let a = line("hi"), b = line("yo")
        let gap = Entry.gapMarker(regionID: region)
        let items = PanelHistory.displayItems(from: [
            line("Kael 21:04", .metadata), line("Mira 21:05", .metadata), a,
            line("Dorn 21:06", .metadata), gap, b,
            line("Zed 21:07", .metadata),
        ])
        #expect(items.map(\.id) == [a.id, gap.id, b.id])
        #expect(items.map(\.speaker) == ["Mira", nil, nil])
        #expect(items.last?.isLatest == true)
    }

    @Test("翻译中的条目也可以是最新一条；没有消息时没有最新")
    func latestPending() {
        let a = line("hi"), b = line("yo", .pending)
        #expect(PanelHistory.displayItems(from: [a, b]).map(\.isLatest) == [false, true])
        #expect(PanelHistory.displayItems(from: [line("Kael 21:04", .metadata)]).isEmpty)
    }
}
