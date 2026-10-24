# 设置页重新设计 实现任务

需求编号对应 `requirements.md`，设计细节见 `design.md`。每个任务完成后编译通过、`TransPeekKit` 测试全部通过。

- [x] 1. Kit 中的模型与逻辑
  - `AppSettings` 新增 `defaultPanelPlacement`、`defaultShowsOriginal`，自定义解码兼容旧数据
  - `ServiceStatus.evaluate`、`SetupProgress`、`ProfileDraft`（脏状态、逐项校验、生成配置）
  - `PresetStore.hasAnyRegion()`
  - 测试：旧数据解码、状态优先级、步骤完成条件、草稿脏状态和校验
  - _需求：S2.2、S2.3、S5.2、S6.2、S7.4、S7.7_

- [x] 2. 框架与通用组件
  - `SettingsRootView`、`SettingsRouter`、`SettingsPage`、`SettingsCard`、`SettingsRow`、`KeyCap`、`StatusLabel`、`ProviderIcon`
  - 记住页面和窗口大小；`WindowPresenter` 和 `AppDelegate` 支持打开指定页面；菜单栏权限警告打开“开始使用”
  - _需求：S1.1–S1.5、S11_

- [x] 3. 简单页面
  - 开始使用、通用（含交换语言）、识别（采样预设）、快捷键、隐私与数据、关于
  - _需求：S2、S3、S4、S8、S9、S10_

- [x] 4. 面板页
  - 实时预览、默认位置、默认显示原文；新区域使用这些默认值
  - _需求：S5_

- [x] 5. 翻译服务
  - 卡片列表、状态、右键和“⋯”菜单、删除确认、复制为新配置、添加服务面板
  - 编辑页：连接分组、逐项校验、测试卡片、高级折叠、底部操作栏、未保存拦截、快捷键
  - 面板中“未配置翻译服务”的提示可点击打开翻译服务页
  - 删除旧的 `SettingsView`、`TranslationProfilesView`、`LLMProfileEditor`
  - _需求：S6、S7、S1.5_

- [x] 6. 收尾
  - 更新 `docs/manual-test.md`、README 中的设置说明；更新 MVP 设计文档中设置界面的描述
  - 验证：编译、打包、启动，打开设置窗口
  - _需求：全部_

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-10-24 | 初版 |
| 2026-10-24 | 完成任务 1–6。界面用离屏截图（Debug 构建 `--settings-snapshots`）检查过全部页面；交互需要手动验收 |
