import CoreGraphics
import Foundation

/// 面板中的一栏，对应一个区域（panel-groups G1）。
public struct PanelSection: Codable, Sendable, Equatable {
    public let regionID: UUID
    /// 比例权重，> 0（G2）。
    public var weight: Double
    /// 折叠后只显示小标题（G3）。
    public var isCollapsed: Bool

    public init(regionID: UUID, weight: Double, isCollapsed: Bool = false) {
        self.regionID = regionID
        self.weight = max(weight, 0.05)
        self.isCollapsed = isCollapsed
    }
}

/// 一个面板窗口，包含一栏或多栏（G1）。面板级设置在所有栏之间共用（G1.3）。
public struct PanelGroup: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var placement: PanelPlacement
    public var opacity: Double
    /// 内侧贴边时折叠成细边（R9.3）。
    public var collapsedStrip: Bool
    /// 顺序即显示顺序（G1.1）。
    public var sections: [PanelSection]
    /// 同一条边上的多个面板按创建顺序排列（G5）。
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        placement: PanelPlacement,
        opacity: Double,
        collapsedStrip: Bool = false,
        sections: [PanelSection] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.placement = placement
        self.opacity = min(max(opacity, PanelConfig.opacityRange.lowerBound), PanelConfig.opacityRange.upperBound)
        self.collapsedStrip = collapsedStrip
        self.sections = sections
        self.createdAt = createdAt
    }

    public var regionIDs: [UUID] { sections.map(\.regionID) }

    public func contains(_ regionID: UUID) -> Bool {
        sections.contains { $0.regionID == regionID }
    }

    /// 由旧版本中区域自己的面板配置生成只有一栏的面板（G6）。
    public static func migrated(from region: Region, createdAt: Date) -> PanelGroup {
        PanelGroup(
            placement: region.panel.placement,
            opacity: region.panel.opacity,
            collapsedStrip: region.panel.collapsed,
            sections: [PanelSection(regionID: region.id, weight: PanelGroupOperations.defaultWeight(for: region.mode))],
            createdAt: createdAt
        )
    }
}

/// 面板的增删改，纯函数，便于测试（G1、G3、G4）。
public enum PanelGroupOperations {
    /// 默认比例：聊天 3，对话和单次 2（G2.3）。
    public static func defaultWeight(for mode: RegionMode) -> Double {
        mode == .chat ? 3 : 2
    }

    /// 让每个区域恰好属于一个面板：去掉不存在的区域和重复的栏，删除空面板，没有面板的区域单独成组（G6）。
    public static func normalized(_ groups: [PanelGroup], regions: [Region]) -> [PanelGroup] {
        let known = Set(regions.map(\.id))
        var seen: Set<UUID> = []
        var result: [PanelGroup] = []
        for var group in groups {
            group.sections = group.sections.filter { known.contains($0.regionID) && seen.insert($0.regionID).inserted }
            if !group.sections.isEmpty { result.append(group) }
        }
        var createdAt = (result.map(\.createdAt).max() ?? Date(timeIntervalSince1970: 0)).addingTimeInterval(1)
        for region in regions where !seen.contains(region.id) {
            result.append(.migrated(from: region, createdAt: createdAt))
            createdAt = createdAt.addingTimeInterval(1)
        }
        return result
    }

    /// 面板名称：其中区域名称按顺序用“ + ”连接（design.md「面板菜单」）。
    public static func displayName(of group: PanelGroup, regions: [Region]) -> String {
        let names = group.regionIDs.compactMap { id in regions.first { $0.id == id }?.name }
        return names.isEmpty ? "面板" : names.joined(separator: " + ")
    }

    public static func groupID(containing regionID: UUID, in groups: [PanelGroup]) -> UUID? {
        groups.first { $0.contains(regionID) }?.id
    }

    /// 把区域加入面板，排在末尾；`groupID` 为 `nil` 或不存在时加入 `newGroup`。返回所在面板的 ID（G4.1）。
    @discardableResult
    public static func add(_ regionID: UUID, mode: RegionMode, to groupID: UUID?, newGroup: @autoclosure () -> PanelGroup, in groups: inout [PanelGroup]) -> UUID {
        remove(regionID, from: &groups)
        let section = PanelSection(regionID: regionID, weight: defaultWeight(for: mode))
        if let groupID, let index = groups.firstIndex(where: { $0.id == groupID }) {
            groups[index].sections.append(section)
            return groupID
        }
        var group = newGroup()
        group.sections = [section]
        groups.append(group)
        return group.id
    }

    /// 移除区域所在的栏；面板变空时删除面板。
    public static func remove(_ regionID: UUID, from groups: inout [PanelGroup]) {
        for index in groups.indices {
            groups[index].sections.removeAll { $0.regionID == regionID }
        }
        groups.removeAll { $0.sections.isEmpty }
    }

    /// 把整个面板的栏加入另一个面板，排在末尾（G4.4）。
    public static func merge(_ groupID: UUID, into targetID: UUID, in groups: inout [PanelGroup]) {
        guard groupID != targetID,
              let sourceIndex = groups.firstIndex(where: { $0.id == groupID }),
              groups.contains(where: { $0.id == targetID })
        else { return }
        let moved = groups.remove(at: sourceIndex).sections
        if let targetIndex = groups.firstIndex(where: { $0.id == targetID }) {
            groups[targetIndex].sections.append(contentsOf: moved)
        }
    }

    /// 上移（`offset < 0`）或下移一栏（G4.3）。
    public static func moveSection(_ regionID: UUID, by offset: Int, in groups: inout [PanelGroup]) {
        guard let groupIndex = groups.firstIndex(where: { $0.contains(regionID) }),
              let index = groups[groupIndex].sections.firstIndex(where: { $0.regionID == regionID })
        else { return }
        let destination = index + offset
        guard groups[groupIndex].sections.indices.contains(destination) else { return }
        groups[groupIndex].sections.swapAt(index, destination)
    }

    /// 折叠或展开一栏。面板中可见的栏至少保留一栏展开（G3.5）。返回是否修改成功。
    @discardableResult
    public static func setCollapsed(_ regionID: UUID, _ collapsed: Bool, visible: Set<UUID>, in groups: inout [PanelGroup]) -> Bool {
        guard let groupIndex = groups.firstIndex(where: { $0.contains(regionID) }),
              let index = groups[groupIndex].sections.firstIndex(where: { $0.regionID == regionID })
        else { return false }
        if collapsed {
            let otherExpanded = groups[groupIndex].sections.contains {
                $0.regionID != regionID && visible.contains($0.regionID) && !$0.isCollapsed
            }
            guard otherExpanded else { return false }
        }
        groups[groupIndex].sections[index].isCollapsed = collapsed
        return true
    }

    /// 在所有可见栏中，是否允许折叠该栏（G3.5）。
    public static func canCollapse(_ regionID: UUID, visible: Set<UUID>, in group: PanelGroup) -> Bool {
        group.sections.contains { $0.regionID != regionID && visible.contains($0.regionID) && !$0.isCollapsed }
    }
}

/// 面板内各栏的尺寸分配（G2）。纯函数。
public enum SectionLayout {
    public struct Item: Sendable, Equatable {
        public var weight: Double
        public var collapsed: Bool

        public init(weight: Double, collapsed: Bool) {
            self.weight = weight
            self.collapsed = collapsed
        }
    }

    /// 栏小标题的高度（左右排列时为宽度方向上的最小尺寸）。
    public static let headerSize: CGFloat = 26
    public static let dividerSize: CGFloat = 6
    /// 展开的栏至少保留小标题 + 一行内容（G2.4）。
    public static let minExpanded: CGFloat = headerSize + 30

    /// 按权重分配长度：折叠栏只占小标题，展开栏按权重分配剩余长度，不小于最小值。
    public static func lengths(total: CGFloat, items: [Item]) -> [CGFloat] {
        guard !items.isEmpty else { return [] }
        let available = max(0, total - dividerSize * CGFloat(items.count - 1))
        var result = items.map { $0.collapsed ? headerSize : 0 }
        var flexible = Set(items.indices.filter { !items[$0].collapsed })
        var remaining = available - result.reduce(0, +)
        // 反复把低于最小值的栏固定为最小值，直到剩下的都满足
        while !flexible.isEmpty {
            let totalWeight = flexible.reduce(0) { $0 + items[$1].weight }
            let tooSmall = flexible.filter { remaining * CGFloat(items[$0].weight / totalWeight) < minExpanded }
            if tooSmall.isEmpty || tooSmall.count == flexible.count {
                for index in flexible {
                    result[index] = tooSmall.count == flexible.count
                        ? max(remaining / CGFloat(flexible.count), 0)
                        : remaining * CGFloat(items[index].weight / totalWeight)
                }
                break
            }
            for index in tooSmall {
                result[index] = minExpanded
                remaining -= minExpanded
                flexible.remove(index)
            }
        }
        return result
    }

    /// 各栏和分隔条的位置。`vertical` 为上下排列。`origin` 是内容区在面板中的起点（原点左上）。
    public static func frames(in rect: CGRect, items: [Item], vertical: Bool) -> (sections: [CGRect], dividers: [CGRect]) {
        let lengths = lengths(total: vertical ? rect.height : rect.width, items: items)
        var sections: [CGRect] = []
        var dividers: [CGRect] = []
        var cursor = vertical ? rect.minY : rect.minX
        for (index, length) in lengths.enumerated() {
            if vertical {
                sections.append(CGRect(x: rect.minX, y: cursor, width: rect.width, height: length))
            } else {
                sections.append(CGRect(x: cursor, y: rect.minY, width: length, height: rect.height))
            }
            cursor += length
            if index < lengths.count - 1 {
                dividers.append(vertical
                    ? CGRect(x: rect.minX, y: cursor, width: rect.width, height: dividerSize)
                    : CGRect(x: cursor, y: rect.minY, width: dividerSize, height: rect.height))
                cursor += dividerSize
            }
        }
        return (sections, dividers)
    }

    /// 两侧都展开时分隔条才可以拖动（G2.1）。
    public static func isDraggable(divider index: Int, items: [Item]) -> Bool {
        items.indices.contains(index + 1) && !items[index].collapsed && !items[index + 1].collapsed
    }

    /// 拖动第 `index` 条分隔条（位于第 index 栏和第 index+1 栏之间）：只修改这两栏的权重，两栏权重之和不变（G2.1）。
    /// - Parameters:
    ///   - delta: 分隔条移动的距离，向下（或向右）为正。
    ///   - startLengths: 开始拖动时各栏的长度。
    public static func dragDivider(_ index: Int, delta: CGFloat, startLengths: [CGFloat], items: [Item]) -> [Double] {
        var weights = items.map(\.weight)
        guard isDraggable(divider: index, items: items), startLengths.count == items.count else { return weights }
        let a = startLengths[index], b = startLengths[index + 1]
        let total = a + b
        guard total > minExpanded * 2 else { return weights }
        let newA = min(max(a + delta, minExpanded), total - minExpanded)
        let sum = weights[index] + weights[index + 1]
        weights[index] = sum * Double(newA / total)
        weights[index + 1] = sum - weights[index]
        return weights
    }
}

extension DockLayoutCalculator {
    /// 一个贴边面板的布局请求。
    public struct GroupRequest: Sendable {
        public let id: UUID
        public let edge: DockEdge
        public let thickness: CGFloat
        public let collapsed: Bool

        public init(id: UUID, edge: DockEdge, thickness: CGFloat, collapsed: Bool) {
            self.id = id
            self.edge = edge
            self.thickness = thickness
            self.collapsed = collapsed
        }
    }

    /// 多个贴边面板：先各自计算（含 R9.2 的回退），再把实际贴在同一条边、同一侧（外侧或内侧）的面板平分这条边的长度（G5）。
    /// 请求的顺序即排列顺序（调用方按创建时间排序）。
    public static func layoutGroups(window: CGRect, requests: [GroupRequest], visibleFrame: CGRect) -> [UUID: DockLayout] {
        var result: [UUID: DockLayout] = [:]
        var buckets: [String: [(UUID, DockLayout)]] = [:]
        var order: [String] = []
        for request in requests {
            let layout = layout(window: window, edge: request.edge, thickness: request.thickness, visibleFrame: visibleFrame, collapsed: request.collapsed)
            let key = "\(layout.edge.rawValue)-\(layout.placement == .outside ? "out" : "in")"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append((request.id, layout))
        }
        for key in order {
            guard let members = buckets[key] else { continue }
            guard members.count > 1 else {
                result[members[0].0] = members[0].1
                continue
            }
            for (position, member) in members.enumerated() {
                var frame = member.1.frame
                if member.1.edge.isHorizontal {
                    let segment = frame.width / CGFloat(members.count)
                    frame.origin.x += segment * CGFloat(position)
                    frame.size.width = segment
                } else {
                    let segment = frame.height / CGFloat(members.count)
                    frame.origin.y += segment * CGFloat(position)
                    frame.size.height = segment
                }
                result[member.0] = DockLayout(frame: frame, placement: member.1.placement, edge: member.1.edge)
            }
        }
        return result
    }
}
