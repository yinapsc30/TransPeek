# 设置页重新设计 设计文档

需求编号对应本目录下的 `requirements.md`（S 开头）。

## 结构

```
App/Settings/
├── SettingsRootView.swift        # NavigationSplitView：侧边栏 + 当前页面，未保存修改的拦截
├── SettingsRouter.swift          # 当前页面、导航栈（翻译服务 → 编辑页），供外部打开指定页面（S1.5）
├── Components/
│   ├── SettingsPage.swift        # 页面容器：标题、说明、滚动区域
│   ├── SettingsCard.swift        # 分组卡片与设置行（标题、控件、下方说明）
│   ├── KeyCap.swift              # 按键样式（S8）
│   ├── StatusLabel.swift         # 圆点 + 文字的状态（S11.1）
│   └── ProviderIcon.swift        # 彩色方块 + 缩写（S6.1）
├── Pages/
│   ├── GettingStartedPage.swift  # S2
│   ├── GeneralPage.swift         # S3
│   ├── RecognitionPage.swift     # S4
│   ├── PanelStylePage.swift      # S5，含 PanelPreview
│   ├── TranslationServicesPage.swift  # S6 列表与添加面板
│   ├── ServiceEditorPage.swift   # S7
│   ├── HotkeysPage.swift         # S8
│   ├── PrivacyPage.swift         # S9
│   └── AboutPage.swift           # S10
└── Models/
    ├── SettingsModels.swift      # 现有 SettingsModel、ProfilesModel、LaunchAtLogin
    ├── ServiceEditorModel.swift  # 编辑草稿、脏状态、逐项校验、保存/还原（S7）
    ├── ServiceStatusStore.swift  # 每个配置的测试结果（仅内存，S6.2）
    └── SetupChecklist.swift      # 三个步骤的状态计算（S2）
```

现有的 `SettingsView.swift`、`TranslationProfilesView.swift`、`LLMProfileEditor.swift` 中的 Google/LLM 编辑器合并到 `ServiceEditorPage`，旧文件删除。`runConnectionTest` 保留，移动到 `ServiceEditorModel`。

## 关键设计

### 导航（S1）

- 侧边栏用自绘按钮实现（`SettingsSidebar`）：选中项固定为系统蓝底白字，悬停时浅灰底；获得焦点后可以用上下方向键切换（S11.2）。第一版用 `NavigationSplitView` + `List(selection:)`，用户实测点击无反应（行的 tag 类型与可选的 selection 类型不一致，改正后在这个窗口中仍不可靠），所以改为自绘。整个设置窗口 `.tint(.systemBlue)`，不跟随系统强调色（S1.7）。
- 页面枚举 `SettingsPane: String, CaseIterable`。上次的页面保存在 `UserDefaults`（`settings.lastPane`），窗口大小由 `NSWindow.setFrameAutosaveName("TransPeekSettings")` 保存（S1.2）。
- `SettingsRouter`（`@MainActor @Observable`）持有 `pane` 和翻译服务页的 `path`（`NavigationStack`）。`WindowPresenter` 打开设置窗口时可以传入页面；已打开时切换页面（S1.5）。菜单栏的权限警告和面板中“未配置翻译服务”的提示通过 `AppDelegate` 调用 `showSettings(pane:)`。
- 侧边栏图标：SF Symbols 放在彩色圆角方块里，颜色固定（与设计稿一致）。
- “开始使用”角标：`SetupChecklist.pendingCount`，用 `.badge()` 显示（S1.4）。

### 卡片与设置行（S1.3）

- `SettingsCard { ... }`：圆角 10，背景 `controlBackgroundColor`，描边 `separatorColor`。所有卡片（含测试结果、开始使用的步骤、选择建议）都用这一种样式，不使用彩色底框（S1.7）。
- `SettingsRow(title:, detail:) { control }`：标题左对齐，控件右对齐，说明文字在标题下方，次要颜色。
- 不使用 `Form(.grouped)`，因为它不能控制说明文字的位置和卡片样式；改为 `ScrollView` + `VStack` 组合。

### 开始使用（S2）

`SetupChecklist` 根据以下数据计算状态，数据变化时重新计算：

- 权限：`PermissionManager.screenCaptureGranted`。
- 翻译服务：解析默认配置，Google 检查 `google-api-key`；LLM 检查模型 ID 非空，预设 `requiresAPIKey` 时检查钥匙串中的 Key（S2.2）。
- 区域：`PresetStore` 新增 `hasAnyRegion()`，扫描 `presets/` 目录中的预设文件；`SessionCoordinator.regions` 非空时直接视为完成（S2.3）。

### 面板页与预览（S5）

- `AppSettings` 新增 `defaultPanelPlacement: DefaultPanelPlacement`（`right` / `left` / `bottom` / `floating`，默认 `right`）和 `defaultShowsOriginal: Bool`（默认 `true`）。`AppSettings` 改为自定义解码，旧数据缺少字段时取默认值。
- `SessionCoordinator.presentNewRegionConfig` 用这些默认值生成新区域的 `PanelConfig`（悬浮时偏移为窗口右上角内侧 24pt，大小 320×360）。
- `PanelPreview`：复用 `PanelContentView` 中的条目样式（把 `EntryRow` 从 `private` 改为模块内可见），用固定的示例条目渲染在深色背景上，不创建真实面板窗口。

### 翻译服务列表（S6）

- 卡片状态由 `ServiceStatus.evaluate(profile, secrets, presets, testResult)` 计算，优先级：缺少 Key → 未填模型 → 测试失败 → 测试通过 → 尚未测试。
- `ServiceStatusStore`（`@Observable`）保存 `[UUID: ConnectionTestState]`；编辑页和列表页的“测试连接”都写入这里。
- 删除确认用 `confirmationDialog`（S6.4）。“复制为新配置”生成新 ID、名称加“副本”、复制钥匙串中的 Key。
- 添加面板：`.sheet` 中的 `LazyVGrid`，第一项是 Google 翻译，其后是 `LLMPresets.json` 中的预设。说明文字来自预设：本地服务显示“本地运行，不需要 Key”，其余显示 Base URL 的主机名（S6.5）。
- `ProviderIcon` 的颜色和缩写按预设 ID 写在一个字典里，未知 ID 用灰色和名称首字母。

### 编辑页（S7）

`ServiceEditorModel`（`@MainActor @Observable`）：

- `original: TranslationProfile?`（新配置为 `nil`）、`draft` 的各字段、`apiKey`、`savedKeySuffix`（末 4 位）。
- `isDirty`：草稿与原值（含 Key）不同。
- `issues: [Field: String]`：每次修改后用 `LLMConfigValidator` 逐项校验（S7.4）；`canSave = isDirty && issues.isEmpty`。
- `save()`、`revert()`、`test()`。
- 离开拦截（S7.8）：`SettingsRouter` 在切换页面和返回前询问当前编辑页 `hasUnsavedChanges`；为真时弹出 `alert`（保存 / 放弃 / 取消）。关闭设置窗口通过 `NSWindowDelegate.windowShouldClose` 同样拦截。
- API Key：`SecureField` 和 `TextField` 切换显示；未修改时显示 `•••• 3f9a` 占位，开始输入后替换（S7.3）。
- “高级”分组：`DisclosureGroup`，默认折叠，标签旁显示摘要（S7.6）。变量按钮在光标处插入不容易实现，改为插入到提示词末尾。
- 快捷键：`.keyboardShortcut("s")` 绑定保存，`.onExitCommand` 返回（S11.2）。

### 识别页（S4）

采样频率预设是 `Picker(.segmented)`，选中“自定义”时显示 `Stepper`。当前值不是 2/4/8 时自动选中“自定义”。

### 隐私与数据（S9）

“在访达中显示”用 `NSWorkspace.shared.activateFileViewerSelecting`，目录不存在时先创建。

## 开发工具

Debug 构建支持 `TransPeek --settings-snapshots <目录>`：离屏渲染每个设置页面和第一个翻译服务的编辑页，保存为 PNG 后退出，用于在没有屏幕录制权限、看不到屏幕时检查布局（`App/Support/DebugSnapshots.swift`，Release 构建不包含）。

带 `step` 参数的 `Slider` 在 macOS 上会画一排刻度点，显得杂乱，改为不设 `step`、通过 `Binding.rounded(to:)` 取整。

## 测试

设置页主要是界面，单元测试覆盖可以独立出来的逻辑：

- Kit：`AppSettings` 旧数据解码取默认值；新字段往返编码。
- App 层的纯逻辑放到可测试的类型中，但 App target 目前没有测试 target。本次把 `ServiceStatus.evaluate`、`SetupChecklist` 的判断函数、`ServiceEditorModel` 的脏状态和校验写成不依赖 AppKit 的代码，放到 Kit 中测试：
  - `ServiceStatus`：五种状态的优先级。
  - `SetupProgress`：三个步骤的完成条件。
  - `ProfileDraft`（编辑草稿的值类型）：脏状态、逐项校验、生成 `TranslationProfile`。
- 界面部分加入 `docs/manual-test.md` 手动验收。

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-10-24 | 初版 |
| 2026-10-24 | 卡片统一为中性样式（S1.7） |
| 2026-10-24 | 实现时调整：语言交换按钮放在目标语言一行；滑块去掉刻度点；新增 Debug 截图工具 |
| 2026-10-24 | 修复侧边栏不能点击：改为自绘按钮；截图工具增加模拟点击检查，并改用内存钥匙串避免授权弹窗阻塞 |
| 2026-10-24 | 面板页预览改为并排显示贴边（HUD 玻璃）和悬浮（字幕）两种样式，与面板共用组件（panel-redesign P9） |
