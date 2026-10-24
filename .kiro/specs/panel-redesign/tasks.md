# 面板外观重新设计 实现任务

需求编号对应 `requirements.md`，设计细节见 `design.md`。每个任务完成后编译通过、`TransPeekKit` 测试全部通过。

- [x] 1. Kit：样式与显示条目
  - `PanelStyle`（由摆放方式决定、背景不透明度计算）
  - `SpeakerLabel.name(fromMetadata:)`，复用 `NoiseFilter` 的时间正则
  - `PanelHistory.displayItems()`：说话人配对、最新一条
  - 测试：见设计文档“测试”一节
  - _需求：P1.1、P1.3、P2.3、P3.2、P3.5、P5_

- [x] 2. 背景、样式切换与悬停状态
  - `VisualEffectBackground`、`PanelBackground`；窗口阴影随样式切换
  - `PanelWindowController.style`、`isHovering`（延迟隐藏、拖动中保持）、`controlsVisible`
  - 标识色 `RegionMode.accent`；折叠细边使用第一栏的标识色
  - _需求：P1、P2.1、P3.1、P3.5、P6_

- [x] 3. 标题与控件
  - 去掉多栏顶部拖动条；统一的 `SectionHeader`，悬停显示按钮，锁定时隐藏
  - `Aa` 工具条；`⋯` 菜单加入“面板”一节
  - 已折叠的栏标题始终显示，点击展开
  - 更新 `../panel-groups/design.md` 中顶部拖动条的说明
  - _需求：P4_

- [x] 4. 栏内容
  - 两种样式的聊天条目、对话（HUD 卡片和历史收起、字幕居中）
  - 状态提示、未配置服务提示条、失败/回退徽章、新消息胶囊、精简显示、分隔条
  - _需求：P2.2–P2.4、P3.1–P3.4、P5、P7、P8.2_

- [x] 5. 设置预览
  - 共用组件移到 `PanelComponents.swift`；面板页并排显示两种样式
  - _需求：P9_

- [x] 6. 收尾
  - Debug 快照工具渲染两种样式的各个状态并检查
  - 更新 `docs/manual-test.md`、README；在 settings-redesign 的 design.md 变更记录中注明
  - 验证：编译、打包、启动
  - _需求：全部_

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-10-24 | 初版 |
| 2026-10-24 | 任务 1–6 完成（Kit 184 个测试通过；Debug 快照工具改为渲染两种样式的各个状态） |
