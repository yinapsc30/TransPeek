# 识别结果整理 实现任务

需求编号对应 `requirements.md`，设计细节见 `design.md`。每个任务完成后编译通过、`TransPeekKit` 测试全部通过。

- [x] 1. 规则过滤
  - 实现 `NoiseFilter`：界面标签移除、乱码行判断、名字/时间行判断
  - 测试：实测数据（`Haka OGLUE 14:39` 等）、反例（`meet at 10:30`、`[14:39] Rex: gg`）、各种时间格式、乱码行
  - _需求：C1.2、C1.3、C1.4_

- [x] 2. 数据模型
  - `Region` 新增 `filtersNoise`、`smartCleanup`，兼容旧预设文件
  - `TranslationState` 新增 `.metadata`、`.hidden`；新增 `TranslationOutput`，provider 接口改为返回 `TranslationOutput`
  - 测试：旧预设解码取默认值、新字段往返编码
  - _需求：C1.1、C2.1_

- [x] 3. LLM 智能整理
  - `TranslationOptions`、`TranslationRequest` 新增 `classifiesLines`；缓存键、缓存值、批量分组键相应调整
  - `PromptBuilder` 拆分规则部分和输出格式部分；`ResponseParser` 解析 `type`
  - `LLMTranslationProvider` 按 `classifiesLines` 组装提示词并返回带类型的结果
  - 测试：两种输出格式、自定义提示词附加格式、类型解析、分开缓存
  - _需求：C2.2、C2.4、C2.6、C2.7_

- [x] 4. 流水线与面板历史
  - `PipelineConfiguration` 新增 `usesLLM`；流水线接入 `NoiseFilter`，名字/时间行直接输出 `.metadata`，聊天去重包含名字/时间行
  - `PanelHistory`：`.hidden` 删除条目、新增数不含 `.metadata`、复制全部包含名字行
  - 测试：规则过滤后的条目、智能整理返回 `.hidden`、对话模式不标注、实测数据回放
  - _需求：C1.5、C1.6、C2.3、C2.5、C2.8、C3.2、C3.3_

- [x] 5. App 层
  - `SessionCoordinator` 根据区域的翻译配置计算 `usesLLM`，翻译配置或全局默认变化时更新流水线
  - `RegionForm` 和框选后的配置窗口新增两个开关
  - `EntryRow` 显示 `.metadata`；`PanelController` 处理未读数减少
  - 更新 README（使用说明）和 `docs/manual-test.md`
  - 验证：编译、打包、启动
  - _需求：C1.1、C2.1、C3.1、C3.2、C3.4_

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-10-24 | 初版 |
| 2026-10-24 | 完成任务 1–5，新增 16 个单元测试；真实窗口和真实 LLM 的效果需要手动验收 |
