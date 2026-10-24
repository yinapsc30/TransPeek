import CoreGraphics
import Foundation
import Testing
@testable import TransPeekKit

@Suite("合并面板：数据与迁移（G1、G6）")
struct PanelGroupModelTests {
    private func region(_ name: String, mode: RegionMode = .chat, placement: PanelPlacement = .docked(edge: .right, thickness: 300)) -> Region {
        Region(name: name, rect: CGRect(x: 0, y: 0, width: 1, height: 1), mode: mode, targetLanguage: .simplifiedChinese,
               panel: PanelConfig(placement: placement, opacity: 0.6, fontSize: 16, showsOriginal: false, collapsed: true))
    }

    @Test("旧预设（schemaVersion 1）迁移：每个区域单独成组，沿用原来的设置")
    func legacyMigration() throws {
        let chat = region("聊天")
        let dialog = region("对话", mode: .dialog, placement: .docked(edge: .bottom, thickness: 140))
        var json = try JSONSerialization.jsonObject(with: JSONCoding.encoder().encode(AppPreset(bundleID: "a.b", regions: [chat, dialog]))) as! [String: Any]
        json.removeValue(forKey: "panelGroups")
        json.removeValue(forKey: "currentGroupID")
        json["schemaVersion"] = 1
        let preset = try JSONCoding.decoder().decode(AppPreset.self, from: JSONSerialization.data(withJSONObject: json))

        #expect(preset.schemaVersion == 2)
        #expect(preset.panelGroups.count == 2)
        #expect(preset.panelGroups[0].regionIDs == [chat.id] && preset.panelGroups[1].regionIDs == [dialog.id])
        #expect(preset.panelGroups[0].placement == .docked(edge: .right, thickness: 300))
        #expect(preset.panelGroups[1].placement == .docked(edge: .bottom, thickness: 140))
        #expect(preset.panelGroups[0].opacity == 0.6 && preset.panelGroups[0].collapsedStrip)
        #expect(preset.panelGroups[0].createdAt < preset.panelGroups[1].createdAt)
        #expect(preset.currentGroupID == preset.panelGroups.last?.id)
    }

    @Test("新格式往返编码")
    func roundTripPreset() throws {
        let a = region("A"), b = region("B", mode: .dialog)
        let group = PanelGroup(placement: .floating(offset: CGPoint(x: 10, y: 20), size: CGSize(width: 300, height: 400)), opacity: 0.8,
                               sections: [PanelSection(regionID: a.id, weight: 3), PanelSection(regionID: b.id, weight: 2, isCollapsed: true)],
                               createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let preset = AppPreset(bundleID: "a.b", regions: [a, b], panelGroups: [group], currentGroupID: group.id, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(try roundTrip(preset) == preset)
    }

    @Test("数据不一致时的防御：重复的栏、不存在的区域、没有面板的区域")
    func normalize() {
        let a = region("A"), b = region("B"), c = region("C")
        let ghost = UUID()
        let groups = [
            PanelGroup(placement: .docked(edge: .right, thickness: 300), opacity: 1, sections: [PanelSection(regionID: a.id, weight: 3), PanelSection(regionID: ghost, weight: 1)]),
            PanelGroup(placement: .docked(edge: .left, thickness: 300), opacity: 1, sections: [PanelSection(regionID: a.id, weight: 3), PanelSection(regionID: b.id, weight: 2)]),
            PanelGroup(placement: .docked(edge: .left, thickness: 300), opacity: 1, sections: [PanelSection(regionID: ghost, weight: 1)]),
        ]
        let result = PanelGroupOperations.normalized(groups, regions: [a, b, c])
        #expect(result.map(\.regionIDs) == [[a.id], [b.id], [c.id]])
    }

    @Test("面板名称由区域名称按顺序连接")
    func displayName() {
        let a = region("聊天频道"), b = region("NPC 对话")
        let group = PanelGroup(placement: .docked(edge: .right, thickness: 300), opacity: 1,
                               sections: [PanelSection(regionID: a.id, weight: 3), PanelSection(regionID: b.id, weight: 2)])
        #expect(PanelGroupOperations.displayName(of: group, regions: [b, a]) == "聊天频道 + NPC 对话")
        #expect(PanelGroupOperations.displayName(of: group, regions: []) == "面板")
    }
}

@Suite("合并面板：操作（G3、G4）")
struct PanelGroupOperationTests {
    let a = UUID(), b = UUID(), c = UUID()
    private func newGroup() -> PanelGroup {
        PanelGroup(placement: .docked(edge: .right, thickness: 320), opacity: 0.85)
    }

    @Test("加入当前面板使用默认比例；加入新面板；面板 ID 不存在时新建")
    func add() {
        var groups: [PanelGroup] = []
        let first = PanelGroupOperations.add(a, mode: .chat, to: nil, newGroup: newGroup(), in: &groups)
        PanelGroupOperations.add(b, mode: .dialog, to: first, newGroup: newGroup(), in: &groups)
        #expect(groups.count == 1)
        #expect(groups[0].sections.map(\.weight) == [3, 2])
        let other = PanelGroupOperations.add(c, mode: .once, to: UUID(), newGroup: newGroup(), in: &groups)
        #expect(groups.count == 2 && other != first)
    }

    @Test("移到其他面板：从原面板移除，原面板变空时删除")
    func moveBetweenGroups() {
        var groups: [PanelGroup] = []
        let g1 = PanelGroupOperations.add(a, mode: .chat, to: nil, newGroup: newGroup(), in: &groups)
        PanelGroupOperations.add(b, mode: .dialog, to: g1, newGroup: newGroup(), in: &groups)
        let g2 = PanelGroupOperations.add(b, mode: .dialog, to: nil, newGroup: newGroup(), in: &groups) // 移到新面板
        #expect(groups.map(\.regionIDs) == [[a], [b]])
        PanelGroupOperations.add(a, mode: .chat, to: g2, newGroup: newGroup(), in: &groups)
        #expect(groups.map(\.regionIDs) == [[b, a]])
        #expect(groups[0].id == g2)
    }

    @Test("合并整个面板；上移下移")
    func mergeAndReorder() {
        var groups: [PanelGroup] = []
        let g1 = PanelGroupOperations.add(a, mode: .chat, to: nil, newGroup: newGroup(), in: &groups)
        let g2 = PanelGroupOperations.add(b, mode: .dialog, to: nil, newGroup: newGroup(), in: &groups)
        PanelGroupOperations.add(c, mode: .dialog, to: g2, newGroup: newGroup(), in: &groups)
        PanelGroupOperations.merge(g2, into: g1, in: &groups)
        #expect(groups.map(\.regionIDs) == [[a, b, c]])
        PanelGroupOperations.moveSection(c, by: -1, in: &groups)
        #expect(groups[0].regionIDs == [a, c, b])
        PanelGroupOperations.moveSection(a, by: -1, in: &groups) // 已在最上面
        #expect(groups[0].regionIDs == [a, c, b])
        PanelGroupOperations.merge(g1, into: g1, in: &groups) // 不能合并到自己
        #expect(groups.count == 1)
    }

    @Test("折叠：至少保留一栏展开，只计算可见（未暂停）的栏")
    func collapse() {
        var groups: [PanelGroup] = []
        let g = PanelGroupOperations.add(a, mode: .chat, to: nil, newGroup: newGroup(), in: &groups)
        PanelGroupOperations.add(b, mode: .dialog, to: g, newGroup: newGroup(), in: &groups)
        #expect(PanelGroupOperations.setCollapsed(a, true, visible: [a, b], in: &groups))
        #expect(!PanelGroupOperations.setCollapsed(b, true, visible: [a, b], in: &groups)) // 最后一栏展开的不能折叠
        #expect(PanelGroupOperations.setCollapsed(a, false, visible: [a, b], in: &groups))
        #expect(!PanelGroupOperations.setCollapsed(a, true, visible: [a], in: &groups)) // b 已暂停，不可见
        #expect(!PanelGroupOperations.canCollapse(a, visible: [a], in: groups[0]))
    }

    @Test("删除区域后清理空面板")
    func remove() {
        var groups: [PanelGroup] = []
        PanelGroupOperations.add(a, mode: .chat, to: nil, newGroup: newGroup(), in: &groups)
        PanelGroupOperations.remove(a, from: &groups)
        #expect(groups.isEmpty)
    }
}

@Suite("合并面板：布局（G2、G5）")
struct SectionLayoutTests {
    typealias Item = SectionLayout.Item

    @Test("按权重分配，扣除分隔条")
    func weights() {
        let lengths = SectionLayout.lengths(total: 506, items: [Item(weight: 3, collapsed: false), Item(weight: 2, collapsed: false)])
        #expect(lengths == [300, 200])
    }

    @Test("折叠栏只占小标题，展开后恢复原比例")
    func collapsed() {
        let collapsed = SectionLayout.lengths(total: 506, items: [Item(weight: 3, collapsed: false), Item(weight: 2, collapsed: true)])
        #expect(collapsed == [500 - SectionLayout.headerSize, SectionLayout.headerSize])
        let expanded = SectionLayout.lengths(total: 506, items: [Item(weight: 3, collapsed: false), Item(weight: 2, collapsed: false)])
        #expect(expanded == [300, 200])
    }

    @Test("不小于最小尺寸")
    func minimum() {
        let lengths = SectionLayout.lengths(total: 406, items: [Item(weight: 20, collapsed: false), Item(weight: 1, collapsed: false)])
        #expect(lengths[1] == SectionLayout.minExpanded)
        #expect(lengths[0] == 400 - SectionLayout.minExpanded)
    }

    @Test("分隔条拖动只改相邻两栏，两栏权重之和不变，不越过最小值")
    func drag() {
        let items = [Item(weight: 3, collapsed: false), Item(weight: 2, collapsed: false), Item(weight: 1, collapsed: false)]
        let start = SectionLayout.lengths(total: 612, items: items) // 300, 200, 100
        #expect(start == [300, 200, 100])
        let weights = SectionLayout.dragDivider(0, delta: 50, startLengths: start, items: items)
        #expect(abs(weights[0] - 3.5) < 1e-9 && abs(weights[1] - 1.5) < 1e-9 && weights[2] == 1)
        let clamped = SectionLayout.dragDivider(0, delta: 1000, startLengths: start, items: items)
        #expect(abs(clamped[0] + clamped[1] - 5) < 1e-9)
        let newLengths = SectionLayout.lengths(total: 612, items: zip(items, clamped).map { Item(weight: $1, collapsed: $0.collapsed) })
        #expect(abs(newLengths[1] - SectionLayout.minExpanded) < 0.5)
        // 折叠栏两侧的分隔条不能拖动
        let withCollapsed = [Item(weight: 3, collapsed: false), Item(weight: 2, collapsed: true)]
        #expect(!SectionLayout.isDraggable(divider: 0, items: withCollapsed))
    }

    @Test("上下排列与左右排列的位置")
    func frames() {
        let items = [Item(weight: 1, collapsed: false), Item(weight: 1, collapsed: false)]
        let vertical = SectionLayout.frames(in: CGRect(x: 0, y: 20, width: 300, height: 406), items: items, vertical: true)
        #expect(vertical.sections == [CGRect(x: 0, y: 20, width: 300, height: 200), CGRect(x: 0, y: 226, width: 300, height: 200)])
        #expect(vertical.dividers == [CGRect(x: 0, y: 220, width: 300, height: 6)])
        let horizontal = SectionLayout.frames(in: CGRect(x: 0, y: 0, width: 606, height: 150), items: items, vertical: false)
        #expect(horizontal.sections[1] == CGRect(x: 306, y: 0, width: 300, height: 150))
    }

    @Test("同一条边上的多个面板平分长度；悬浮面板不参与；回退到同一条边时也平分")
    func sameEdge() {
        let screen = CGRect(x: 0, y: 30, width: 1920, height: 1170)
        let window = CGRect(x: 300, y: 100, width: 1000, height: 800)
        let first = UUID(), second = UUID(), third = UUID()
        let result = DockLayoutCalculator.layoutGroups(window: window, requests: [
            .init(id: first, edge: .right, thickness: 300, collapsed: false),
            .init(id: second, edge: .right, thickness: 300, collapsed: false),
            .init(id: third, edge: .left, thickness: 200, collapsed: false),
        ], visibleFrame: screen)
        #expect(result[first]?.frame == CGRect(x: 1300, y: 100, width: 300, height: 400))
        #expect(result[second]?.frame == CGRect(x: 1300, y: 500, width: 300, height: 400))
        #expect(result[third]?.frame == CGRect(x: 100, y: 100, width: 200, height: 800))

        // 窗口贴着屏幕右边缘：右侧的面板回退到左侧，与左侧的面板平分
        let nearRight = CGRect(x: 1000, y: 100, width: 920, height: 800)
        let fallback = DockLayoutCalculator.layoutGroups(window: nearRight, requests: [
            .init(id: first, edge: .left, thickness: 300, collapsed: false),
            .init(id: second, edge: .right, thickness: 300, collapsed: false),
        ], visibleFrame: screen)
        #expect(fallback[first]?.frame == CGRect(x: 700, y: 100, width: 300, height: 400))
        #expect(fallback[second]?.frame == CGRect(x: 700, y: 500, width: 300, height: 400))
    }
}
