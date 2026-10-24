# 面板外观重新设计 设计文档

需求编号对应本目录下的 `requirements.md`（P 开头）。本功能只改面板的 SwiftUI 视图和少量窗口属性，面板的位置、调整大小、分隔条、流水线都不变（P8）。

## Kit（可测试的纯逻辑）

### 样式 `PanelStyle`（P1）

```swift
public enum PanelStyle: Sendable, Equatable {
    case hud        // 贴边（外侧或内侧）
    case subtitle   // 悬浮

    public init(placement: PanelPlacement)

    /// 背景底色的不透明度。`opacity` 为用户设置（0.2...1.0）。
    public func backgroundOpacity(_ opacity: Double, inside: Bool, hovering: Bool) -> Double
}
```

背景不透明度（P1.3、P2.1、P3.5）：

| 样式 | 计算 | 默认设置 0.85 时 |
|---|---|---|
| HUD 外侧 | `opacity × 0.8`（叠在毛玻璃上，玻璃本身有一定遮盖） | 0.68 |
| HUD 内侧 | `min(opacity, 0.75) × 0.8`（沿用 R9.3） | 0.60 |
| 字幕静止 | `opacity × 0.3` | 0.26 |
| 字幕悬停 | `min(0.85, opacity × 0.3 + 0.4)` | 0.66 |

### 说话人与显示条目（P2.3、P3.2、P5）

`SpeakerLabel.name(fromMetadata:) -> String?`：用 `NoiseFilter` 中已有的结尾时间正则（`trailingTime`，改为 `internal static` 供复用）去掉时间，再去掉时间前的日期词（`Today at`、`Yesterday at`、`今天`、`昨天`、`前天`，Discord 的名字行是“Kael — Today at 21:04”），最后去掉首尾空白和常见分隔符（`-`、`—`、`·`、`|`、`:`）；结果为空返回 `nil`（P5.2）。

`PanelHistory.displayItems() -> [DisplayItem]`：

```swift
public struct DisplayItem: Sendable, Identifiable, Equatable {
    public let entry: Entry          // .line 或 .gapMarker
    public let speaker: String?      // 来自紧挨着的上一条名字行（P5.1）
    public let isLatest: Bool        // 最后一条消息行（P2.3、P3.2、P3.3）
    public var id: UUID { entry.id }
}
```

规则：
1. 按顺序遍历 `entries`。名字行（`.metadata`）不输出，只记下说话人；下一条消息行使用它，之后清空（P5.1、P5.3）。
2. 连续两条名字行时以后一条为准；遗漏标记清空记下的说话人（遗漏的消息之后名字可能对不上）。
3. 末尾的名字行（消息还没出现）不显示。
4. `isLatest`：最后一条 `.line` 且不是名字行的条目。翻译中（`.pending`）的条目也可以是最新一条。
5. “复制全部”继续使用 `plainText`，不受影响（P5.4）。

## App 层

### 背景（P1、P2.1、P3.1）

- 新增 `PanelBackground(style:opacity:inside:hovering:accent:collapsedStrip:)`：
  - HUD：`VisualEffectBackground`（`NSViewRepresentable` 包装 `NSVisualEffectView`，`material = .hudWindow`，`blendingMode = .behindWindow`，`state = .active`。面板永远不是 key 窗口，必须设为 `.active`，否则显示为非活跃的灰色），上面叠深色底色 `#14171D` × `backgroundOpacity`，圆角 12，0.5pt 白色 12% 描边。圆角用 `NSVisualEffectView.maskImage`（可拉伸的圆角图），SwiftUI 的 `clipShape` 不能裁剪 AppKit 视图。
  - 字幕：只有黑色 × `backgroundOpacity` 的圆角矩形，没有毛玻璃；悬停时加 1pt 白色 18% 描边（P3.5）。
  - 折叠细边：第一栏的标识色（P1.4）。
- 窗口阴影：HUD 开启；字幕关闭（透明面板的阴影会在游戏画面上留下灰边）。样式变化时由 `PanelWindowController` 设置 `panel.hasShadow` 并 `invalidateShadow()`。
- 样式由 `PanelWindowController.style`（计算属性，来自 `group.placement`）决定，`dockPlacement == .inside` 决定内侧。拖动过程中不切换，松开后随新位置切换（P1.2）。

### 悬停状态（P3.5、P4.1）

- `PanelWindowController` 新增 `private(set) var isHovering`。`PanelHostingView.onHoverChange` 现在只用于折叠细边，改为同时更新 `isHovering`（已经是 `.activeAlways` 跟踪区域，游戏在前台时也有效）。
- 进入立即显示；离开后延迟 0.4s 隐藏，避免移到菜单或边缘时闪烁。拖动、调整大小、拖动分隔条期间保持显示。
- 控件用 `.opacity(0/1)` 加 `.allowsHitTesting` 隐藏，不从视图层级移除：打开的 `Menu` 锚点仍在，菜单不会因为鼠标移到菜单窗口上而关闭；辅助功能树中仍有这些按钮（P4.7，用 Accessibility Inspector 验证）。动画 0.15s。
- 锁定时 `controlsVisible = false`（P4.2）。

### 标题（P4）

- 去掉多栏顶部拖动条：`PanelWindowController.stripHeight` 删除，`contentRect` 从 0 开始；多栏悬浮面板的最小高度改为 `SectionLayout.minExpanded × 2`。
- 单栏和多栏统一使用 `SectionHeader(window:section:style:)`，高度 26pt（`SectionLayout.headerSize`），整条可以拖动面板（沿用 `PanelDragModifier`）。
  - 左侧：折叠开关（多栏且悬停时显示，P4.5、P4.6）、标识色圆点、名称、模式。HUD 样式中名称为 12pt 粗体；字幕样式中为 10pt、白色 55%，没有圆点和模式（P3.1）。
  - 右侧（悬停时显示）：`Aa`、`⋯`、`×`。按钮为 22×20 的圆角方块，悬停时底色白色 10%。
  - 已折叠的栏：标题始终显示，带新消息数徽章（标识色）；点击标题任意位置展开（`TapGesture` 与拖动手势用 `.simultaneousGesture` 组合，拖动距离超过 2pt 时不触发点击）。左右排列时的折叠竖条同样点击展开。
  - `×`：单栏面板关闭该栏（即整个面板）；多栏面板关闭该栏（G1.7）。
- `Aa` 工具条（P4.3）：`SectionController.isShowingTextTools`（不保存）。展开时在标题下方插入 28pt 的一行：`A−`、当前字号、`A+`、“原文”开关。再次点击 `Aa` 收起；鼠标离开面板 0.4s 后（与控件隐藏同时）收起。工具条占用该栏内容区的高度，不改变栏的比例。
- `⋯` 菜单（P4.4）：
  - 栏的选项（多栏时）：折叠/展开、上移、下移、移到新面板、移到 ▸。
  - 栏的内容：复制全部、清空历史。字号和原文已在 `Aa` 中，菜单中不再重复。
  - “面板”一节：位置 ▸（贴合四边、悬浮、内侧时折叠为细边）、背景不透明度 ▸、合并到 ▸（有其他面板时）、关闭面板（多栏时，暂停全部，G1.7）。

### 标识色（P6）

`extension RegionMode { var accent: Color }`：聊天 `systemBlue`，对话 `systemOrange`，单次 `systemGreen`。浅色变体（说话人标签、对话卡片中的说话人）用 `accent` 与白色 55% 混合，深色背景上更易读。

### 栏内容（P2、P3、P5、P7、P8.2）

视图按 `style` 分支，数据都来自 `SectionController`，条目来自 `history.displayItems()`。

聊天和单次：

| | HUD | 字幕 |
|---|---|---|
| 说话人 | 消息上方单独一行，`fontSize × 0.75`，标识色浅色 | 同一行前缀，`fontSize × 0.75`，标识色浅色，`firstTextBaseline` 对齐 |
| 译文 | `fontSize`，白色 95% | `fontSize`，白色；最新一条 `semibold` |
| 原文 | `fontSize × 0.8`，白色 55%，所有条目（`showsOriginal`） | 只在最新一条下方，白色 75%（P3.3） |
| 最新一条 | 左侧 2.5pt 标识色竖条 | 加粗 |
| 行距 | 条目间 10pt | 条目间 6pt |

- 字幕样式的所有文字加两层阴影：`shadow(.black 90%, radius 1, y 1)` 和 `shadow(.black 60%, radius 3)`，模拟描边（P3.1）。
- 翻译中：译文位置显示原文，白色 55%；失败：原文 + 橙色“翻译失败”小徽章 + “重试”链接；已回退：黄色“已回退”小徽章（P7.3）。
- 遗漏标记：细线中间“可能有遗漏”，橙色 70%。

对话：

- HUD：当前文本为卡片（圆角 10，白色 6% 底，左侧 3pt 标识色边条，内边距 12），译文 `fontSize × 1.15`、`medium`，原文在下方。卡片下方“▸ 之前的对话 N”按钮切换历史（`SectionController.isDialogHistoryExpanded`，不保存），展开后为 HUD 聊天样式的列表（新的在上），白色 75%（P2.4）。
- 字幕：当前文本居中，`fontSize × 1.25`、`semibold`，原文在下方；不显示历史（P3.4）。

状态提示（P7）：

- `SectionPlaceholder(symbol:text:)`：栏内容区居中，SF Symbol 20pt + 文字 12pt，白色 55%。空间小于 80pt 时只显示一行文字。状态和图标：等待识别 `text.viewfinder`、已暂停 `pause.circle`、窗口已关闭 `macwindow.badge.xmark`（不可用时退回 `xmark.rectangle`）、正在加载模型 `ProgressView` 小号、单次 `command`（文字“按 ⌃⌥R 识别”）。
- 未配置翻译服务：栏顶部 22pt 的提示条，黄色 15% 底、黄色文字，右侧“去设置 ›”，点击打开设置（P7.2）。
- “↓ N 条新消息”：标识色胶囊，白色粗体 11pt，阴影（P7.4）。

精简显示（P8.2）：栏高度小于 80pt 时只显示最新一条，HUD 用普通文字，字幕用带阴影的文字。

分隔条：HUD 为白色 8% 细线，悬停时中间显示 30×4 的手柄；字幕为白色 18% 虚线，悬停时同样显示手柄。命中区域不变（G2.1）。

### 设置预览（P9）

- 把背景、栏标题（无按钮的静态版本）、聊天条目视图改为 `internal`，放在 `App/Panel/PanelComponents.swift`，面板和设置预览共用。
- `PanelStylePage` 的预览改为并排两个示例（“贴边”HUD、“悬浮”字幕），各 230pt 宽。示例数据用固定的 `SectionController`（与 Debug 快照工具相同的做法，包含名字行，演示说话人标签），字号和显示原文通过 `update(region:)` 实时更新。预览中的毛玻璃使用 `blendingMode = .withinWindow`，模糊示例画面；用 `.behindWindow` 会在设置窗口上“挖洞”露出桌面。

## 测试

- Kit：
  - `PanelStyle`：由摆放方式决定样式；各情况下的背景不透明度；字幕比 HUD 透明。
  - `SpeakerLabel`：去掉各种格式的时间（`21:04`、`下午 9:04`、`[9:04 PM]`）、分隔符；只有时间时返回 `nil`。
  - `displayItems`：名字行成为下一条消息的说话人；连续名字行取后一条；遗漏标记清空；末尾名字行不显示；`isLatest` 只标记最后一条消息；隐藏的条目已删除，不影响配对。
- Debug 快照工具：每种样式渲染静止、悬停、`Aa` 工具条展开、折叠一栏、精简显示。离屏渲染拍不到毛玻璃（由窗口服务器合成），快照中只能看到底色，毛玻璃效果需要实机确认。
- 手动验收：加入 `docs/manual-test.md`。

## 对其他 spec 的影响

- `../panel-groups/design.md`：多栏顶部拖动条由本设计替代（P4.4），在其“控制器拆分”一节注明。
- `../settings-redesign/`：面板页预览改为两种样式（P9），在其 design.md 的变更记录中注明。

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-10-24 | 初版 |
| 2026-10-24 | 实现时调整：说话人标签额外去掉日期词（Discord 格式）；毛玻璃视图不参与命中测试（否则会吞掉标题拖动和按钮点击）；设置预览用窗口内模糊；栏标题用“底层拖动区 + 上层按钮”的叠放，拖动和“点击展开”由同一个 `DragGesture(minimumDistance: 0)` 区分，避免和按钮的点击冲突；HUD 条目和对话卡片固定为内容高度，竖条不撑满整栏 |
