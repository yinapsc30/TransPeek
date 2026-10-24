# 合并面板 实现任务

需求编号对应 `requirements.md`，设计细节见 `design.md`。每个任务完成后编译通过、`TransPeekKit` 测试全部通过。

- [x] 1. 数据模型与迁移
  - `PanelGroup`、`PanelSection`；`AppPreset` 新增 `panelGroups`、`currentGroupID`，`schemaVersion` 升为 2
  - 旧预设迁移：每个区域单独成组，沿用原来的设置
  - 测试：编码往返、旧预设迁移、区域不属于任何面板时的防御处理
  - _需求：G1.3、G1.4、G6_

- [x] 2. 面板操作与布局计算
  - `PanelGroupOperations`：加入、移出、移到其他面板、合并、排序、折叠、删除区域后清理空面板、默认权重
  - `SectionLayout`：按权重分配、最小尺寸、折叠栏、分隔条拖动
  - `DockLayoutCalculator.layoutGroups`：同一条边的多个面板平均分段
  - 测试：见设计文档“测试”一节
  - _需求：G1.1、G1.2、G2、G3.2、G3.5、G4.3–G4.5、G5_

- [x] 3. 控制器拆分
  - `PanelController` 拆为 `PanelWindowController` 和 `SectionController`
  - `SessionCoordinator` 按面板管理窗口、按区域管理栏；面板配置写回预设；暂停的区域不显示，全部暂停时隐藏面板
  - 关闭栏暂停该区域，关闭面板暂停全部
  - _需求：G1.3–G1.7_

- [x] 4. 多栏界面
  - `PanelGroupView`：单栏保持现状；多栏时的顶部拖动条、栏小标题、折叠开关、新消息数
  - 分隔条在 AppKit 层处理拖动；按栏判断精简显示
  - 面板菜单：每栏的折叠、排序、移出、移到其他面板；合并到其他面板
  - _需求：G1.2、G1.5、G2.1、G2.5、G3、G4.3、G4.4_

- [x] 5. 区域配置与管理
  - 框选后的配置新增“显示在”，默认当前面板；区域管理新增“面板”选择
  - 当前面板的记录与更新
  - _需求：G4.1、G4.2、G4.6_

- [x] 6. 收尾
  - 更新 `docs/manual-test.md`、README；在 MVP 设计文档中注明 R11.7 由本 spec 替代
  - 验证：编译、打包、启动
  - _需求：全部_

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-10-24 | 初版 |
| 2026-10-24 | 任务 1–6 完成（Kit 177 个测试通过；Debug 快照工具新增合并面板的渲染和分隔条、折叠模拟） |
