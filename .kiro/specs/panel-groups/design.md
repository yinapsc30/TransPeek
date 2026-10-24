# 合并面板 设计文档

需求编号对应本目录下的 `requirements.md`（G 开头）。

## 数据模型

```swift
/// 一个面板（G1）。保存在 AppPreset 中。
public struct PanelGroup: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var placement: PanelPlacement      // 面板级（G1.3）
    public var opacity: Double
    public var collapsedStrip: Bool           // 内侧贴边折叠成细边（R9.3）
    public var sections: [PanelSection]       // 顺序即显示顺序（G1.1）
    public var createdAt: Date                // 同一条边上的排列顺序（G5）
}

public struct PanelSection: Codable, Sendable, Equatable {
    public let regionID: UUID
    public var weight: Double                 // 比例权重，> 0（G2）
    public var isCollapsed: Bool              // G3
}
```

- `AppPreset` 新增 `panelGroups: [PanelGroup]` 和 `currentGroupID: UUID?`（G4.2），`schemaVersion` 升为 2。
- `Region.panel`（`PanelConfig`）只保留栏级含义：`fontSize`、`showsOriginal`。`placement`、`opacity`、`collapsed` 字段保留在结构中用于迁移，不再被面板读取。
- 迁移（G6）：`schemaVersion < 2` 或 `panelGroups` 为空时，为每个区域生成 `PanelGroup(placement: region.panel.placement, opacity: region.panel.opacity, collapsedStrip: region.panel.collapsed, sections: [PanelSection(regionID, weight: 默认权重, isCollapsed: false)])`。权重使用 G2.3 的默认值，之后合并到其他面板时比例直接可用。区域在预设中存在但不属于任何面板时，同样单独成组（防御数据不一致）。
- 规范化（`PanelGroupOperations.normalized`）：去掉不存在的区域和重复的栏、删除空面板、为没有面板的区域单独成组。解码和 `AppPreset.init` 都会执行，保证内存中的预设与读回的预设一致；`currentGroupID` 无效时取最后一个面板。
- 纯逻辑放在 Kit 的 `PanelGroupOperations`（可单元测试）：加入、移出、移到其他面板、合并、上移下移、折叠、删除区域时清理空面板、默认权重（G2.3：聊天 3、对话/单次 2）。

## 布局计算

### 栏的分配（Kit：`SectionLayout`）

输入：面板内容区的长度（上下排列时为高度，左右排列时为宽度）、可见栏（未暂停的区域）的权重和折叠状态、栏小标题高度 `headerSize = 26`（与单栏标题栏一致）、分隔条 `dividerSize = 6`、最小展开尺寸 `minExpanded = headerSize + 30`。

1. 折叠栏只占 `headerSize`。
2. 剩余长度减去分隔条后，按展开栏的权重分配；某栏低于 `minExpanded` 时固定为最小值，其余栏重新分配（G2.4）。
3. 输出每栏的起点和长度。
4. 拖动分隔条（G2.1）：只修改相邻两栏的权重，两栏权重之和不变；按两栏的像素长度换算，并限制在最小值以上。折叠栏两侧的分隔条不可拖动。
5. 折叠后展开（G3.2）：权重未改动，所以恢复原来的比例。

### 同一条边的多个面板（G5）

`DockLayoutCalculator` 新增 `layoutGroups(window:, requests: [GroupRequest], visibleFrame:)`：先对每个贴边面板计算实际贴合的边（R9.2 的回退逻辑），再把实际边相同、且同为外侧或同为内侧的面板按请求顺序把该边的长度平均分段，每个面板取一段（外侧和内侧的面板不会重叠，不需要分段）。调用方按 `createdAt` 排序，悬浮面板和隐藏的面板不放入请求。

App 层由 `SessionCoordinator.layoutAllPanels()` 统一计算：目标窗口移动、面板显示/隐藏、位置或厚度变化时调用，结果交给各面板的 `applyLayout`。正在拖动的面板不移动。

## App 层

### 控制器拆分

- `PanelWindowController`（原 `PanelController` 的窗口部分）：一个 `TranslationPanel` 窗口，负责位置、贴边、悬浮、吸附、调整大小、折叠细边、锁定、可见性（沿用现有实现），以及栏的比例和折叠。持有 `[SectionController]`（与 `group.sections` 同序，包含已暂停的区域）。
  - 面板级修改（位置、不透明度、比例、折叠）通过 `onGroupChange` 写回；拖动、调整大小和拖动分隔条期间只更新本地状态，松开后再写回。
  - 会改变面板结构或区域状态的操作（关闭栏、关闭面板、排序、移动、合并）通过 `onCommand(PanelCommand)` 交给 `SessionCoordinator`。
  - 所有可见栏都记录为折叠时（例如唯一展开的栏被暂停），第一栏按展开显示（G3.5 的兜底）。
- `SectionController`（原 `PanelController` 的条目部分）：一个区域的 `PanelHistory`、未读数、自动滚动、字号、显示原文、折叠期间的新消息数（G3.3，对话模式每段新文本算一条）。折叠时列表被移除，不改变“是否在底部”；展开后在底部则滚动到底部。
- `PanelGroupView`（SwiftUI）：
  - 只有一栏时：与现在相同，面板标题栏即该栏标题（G1.5）。
  - 多栏时：~~面板顶部是一条 20pt 的拖动条（拖动手柄或锁定图标、面板名称、面板菜单、关闭整个面板），下面是各栏；~~（已由 `../panel-redesign/` P4.4 替代：去掉顶部拖动条，拖动任一栏标题移动面板，面板级选项在每栏“⋯”菜单的“面板”一节；栏标题的按钮改为悬停显示，字号和原文合并到“Aa”工具条）每栏的小标题包含折叠开关（chevron）、名称、模式、折叠时的新消息数、字号和原文按钮（栏宽小于 230pt 时只在菜单中提供）、栏菜单、关闭按钮。
  - 按 `SectionLayout.frames` 的结果放置每栏；左右排列时折叠的栏显示为一条竖条（只有展开按钮和新消息数）。分隔条用 AppKit 层处理拖动（与调整大小相同的方式，`PanelHostingView` 的命中测试中加入分隔条区域），保证游戏在前台时也能拖动。
- `SessionCoordinator`：`sessions` 改为按区域保存流水线和 `SectionController`，另外按面板保存 `PanelWindowController`（`syncPanels()` 按 `panelGroups` 创建、更新、删除窗口）。区域的流水线事件投递给对应的 `SectionController`。面板配置变化时写回 `AppPreset.panelGroups` 并保存（防抖，R4.7）。
- 关闭栏或面板：目标窗口已关闭时只隐藏该栏，不改变区域的暂停状态（与 R3.6 原有行为一致）；否则暂停区域。

### 面板菜单（G3.1、G4.3、G4.4）

在现有菜单（位置、不透明度、复制全部、清空历史）基础上，多栏时增加每一栏的子菜单：折叠/展开、上移、下移、移到新面板、移到 ▸（其他面板）、字号、显示原文、复制全部、清空历史；以及“合并到 ▸（其他面板）”。每栏小标题上的“⋯”菜单内容与该子菜单相同。单栏面板只有“移到 ▸”和“合并到 ▸”。上移、下移与相邻的可见栏交换（跳过已暂停的栏）。面板名称用其中区域名称连接，例如“聊天频道 + NPC 对话”（`PanelGroupOperations.displayName`）。

### 区域配置与管理（G4.1、G4.6）

- `RegionConfigView` 新增“显示在”选择，默认“当前面板”。
- `RegionManagerView` 的区域表单新增“面板”选择，选项同上（区域所在的面板标为“当前面板”），点击“保存”后生效。
- 新面板的位置、不透明度、折叠细边使用设置中的默认面板样式（S5.2）。
- “当前面板”：用户最近一次点击、拖动、调整过的面板，或最近加入区域的面板；保存在 `AppPreset.currentGroupID`。

## 测试

- Kit：
  - `PanelGroup` 编码；旧预设迁移（G6）。
  - `PanelGroupOperations`：加入（默认权重）、移出、移到其他面板、合并、排序、删除区域后清理空面板、至少保留一栏展开（G3.5）。
  - `SectionLayout`：按权重分配、最小尺寸、折叠栏、分隔条拖动只影响相邻两栏且总和不变、折叠后展开恢复比例。
  - `DockLayoutCalculator.layoutGroups`：同一条边平均分段、因回退换到同一条边的情况、悬浮面板不参与。
- 手动验收：加入 `docs/manual-test.md`。

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-10-24 | 初版 |
| 2026-10-24 | 实现时调整：小标题 26pt、分隔条 6pt、最小展开尺寸 56pt；迁移使用默认权重；`AppPreset.init` 也做规范化；`layoutGroups` 按实际边和内外侧分组，由 `layoutAllPanels` 统一调用；控制器通过 `onGroupChange` / `onCommand` 与协调器通信；补充所有栏折叠时的兜底、左右排列时折叠栏的竖条、窄栏把按钮收进菜单、目标窗口关闭后关闭栏只隐藏、区域管理中的面板选择在保存时生效 |
| 2026-10-24 | 多栏顶部拖动条、栏标题按钮由 panel-redesign（P4）替代 |
