import Foundation

/// 按应用（Bundle ID）保存的区域和面板配置（R4.7、panel-groups G1）。
public struct AppPreset: Codable, Sendable, Equatable {
    /// 2：新增 `panelGroups` 和 `currentGroupID`（panel-groups）。
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public let bundleID: String
    public var regions: [Region]
    /// 面板，每个区域恰好属于一个面板。
    public var panelGroups: [PanelGroup]
    /// 新框选的区域默认加入的面板（G4.2）。
    public var currentGroupID: UUID?
    public var updatedAt: Date

    public init(bundleID: String, regions: [Region] = [], panelGroups: [PanelGroup] = [], currentGroupID: UUID? = nil, updatedAt: Date = Date()) {
        self.schemaVersion = Self.currentSchemaVersion
        self.bundleID = bundleID
        self.regions = regions
        // 与解码时一致：保证每个区域恰好属于一个面板，当前面板有效
        let groups = PanelGroupOperations.normalized(panelGroups, regions: regions)
        self.panelGroups = groups
        self.currentGroupID = groups.contains { $0.id == currentGroupID } ? currentGroupID : groups.last?.id
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, bundleID, regions, panelGroups, currentGroupID, updatedAt
    }

    /// 旧版本（schemaVersion 1）没有面板数据：每个区域生成一个只有一栏的面板，沿用原来的设置（G6）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        bundleID = try c.decode(String.self, forKey: .bundleID)
        regions = try c.decodeIfPresent([Region].self, forKey: .regions) ?? []
        let groups = try c.decodeIfPresent([PanelGroup].self, forKey: .panelGroups) ?? []
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
        panelGroups = PanelGroupOperations.normalized(groups, regions: regions)
        let current = try c.decodeIfPresent(UUID.self, forKey: .currentGroupID)
        currentGroupID = panelGroups.contains { $0.id == current } ? current : panelGroups.last?.id
        schemaVersion = Self.currentSchemaVersion
    }

    public static func empty(bundleID: String) -> AppPreset {
        AppPreset(bundleID: bundleID, updatedAt: Date(timeIntervalSince1970: 0))
    }
}
