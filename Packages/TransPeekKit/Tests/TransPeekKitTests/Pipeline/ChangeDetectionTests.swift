import CoreGraphics
import Testing
@testable import TransPeekKit

@Suite("ChangeDetector")
struct ChangeDetectorTests {
    let detector = ChangeDetector()

    private func thumbnail(_ image: CGImage?) throws -> GrayThumbnail {
        let unwrapped = try #require(image)
        return try #require(GrayThumbnail(image: unwrapped))
    }

    @Test("缩放到宽 128 并保持比例；小图不放大")
    func thumbnailSize() throws {
        let large = try thumbnail(makeSolidImage(width: 1200, height: 200, gray: 10))
        #expect(large.width == 128 && large.height == 21)
        let small = try thumbnail(makeSolidImage(width: 40, height: 10, gray: 10))
        #expect(small.width == 40 && small.height == 10)
    }

    @Test("完全相同的画面没有变化")
    func identical() throws {
        let a = try thumbnail(makeSolidImage(width: 600, height: 100, gray: 120))
        let b = try thumbnail(makeSolidImage(width: 600, height: 100, gray: 120))
        #expect(detector.difference(a, b) == 0)
        #expect(!detector.isChanged(from: a, to: b))
    }

    @Test("轻微噪声不视为变化")
    func smallNoise() throws {
        let a = try thumbnail(makeImage(width: 600, height: 100) { _, _ in 120 })
        let b = try thumbnail(makeImage(width: 600, height: 100) { x, y in (x + y) % 2 == 0 ? 121 : 119 })
        #expect(!detector.isChanged(from: a, to: b))
    }

    @Test("出现新的一行文字视为变化")
    func newTextLine() throws {
        let a = try thumbnail(makeSolidImage(width: 600, height: 100, gray: 30))
        // 底部 20% 出现白色“文字”条纹
        let b = try thumbnail(makeImage(width: 600, height: 100) { x, y in y > 80 && x % 6 < 3 ? 230 : 30 })
        #expect(detector.isChanged(from: a, to: b))
    }

    @Test("没有基准或尺寸变化时视为变化")
    func missingBaselineOrResize() throws {
        let a = try thumbnail(makeSolidImage(width: 600, height: 100, gray: 30))
        let b = try thumbnail(makeSolidImage(width: 600, height: 200, gray: 30))
        #expect(detector.isChanged(from: nil, to: a))
        #expect(detector.isChanged(from: a, to: b))
    }
}

@Suite("StabilityGate")
struct StabilityGateTests {
    @Test("没有变化时保持空闲")
    func idle() {
        var gate = StabilityGate()
        #expect(gate.feed(changedFromBaseline: false, movedSincePreviousFrame: false, now: 0) == .idle)
        #expect(!gate.isWaiting)
    }

    @Test("变化后稳定 250ms 放行（4fps 下为下一帧）")
    func firesWhenStable() {
        var gate = StabilityGate()
        #expect(gate.feed(changedFromBaseline: true, movedSincePreviousFrame: true, now: 0.0) == .waiting)
        #expect(gate.feed(changedFromBaseline: true, movedSincePreviousFrame: false, now: 0.25) == .fire(forced: false))
        #expect(!gate.isWaiting)
    }

    @Test("持续变化超过 1s 强制放行")
    func forcedAfterMaxWait() {
        var gate = StabilityGate()
        #expect(gate.feed(changedFromBaseline: true, movedSincePreviousFrame: true, now: 0.0) == .waiting)
        for t in stride(from: 0.25, to: 1.0, by: 0.25) {
            #expect(gate.feed(changedFromBaseline: true, movedSincePreviousFrame: true, now: t) == .waiting)
        }
        #expect(gate.feed(changedFromBaseline: true, movedSincePreviousFrame: true, now: 1.0) == .fire(forced: true))
    }

    @Test("放行后状态重置，可以再次进入等待")
    func resetsAfterFire() {
        var gate = StabilityGate()
        _ = gate.feed(changedFromBaseline: true, movedSincePreviousFrame: true, now: 0)
        _ = gate.feed(changedFromBaseline: true, movedSincePreviousFrame: false, now: 0.3)
        #expect(gate.feed(changedFromBaseline: false, movedSincePreviousFrame: false, now: 0.6) == .idle)
        #expect(gate.feed(changedFromBaseline: true, movedSincePreviousFrame: true, now: 0.9) == .waiting)
    }

    @Test("画面闪烁后回到原样，不触发识别")
    func flickerBackToBaseline() {
        var gate = StabilityGate()
        _ = gate.feed(changedFromBaseline: true, movedSincePreviousFrame: true, now: 0)
        #expect(gate.feed(changedFromBaseline: false, movedSincePreviousFrame: true, now: 0.1) == .waiting)
        #expect(gate.feed(changedFromBaseline: false, movedSincePreviousFrame: false, now: 0.4) == .idle)
    }
}
