# 识别结果整理 设计文档

需求编号对应本目录下的 `requirements.md`（C 开头）；R 开头的编号对应 `../transpeek-mvp/requirements.md`。

## 处理流程

```
OCR 片段 → LineAssembler（含区域忽略规则，C1.6）→ 丢弃半截行（聊天模式）
        → NoiseFilter（开关开启时）：移除界面标签 → 丢弃乱码行 → [未启用智能整理时] 标记名字/时间行
        → 聊天去重（消息行 + 名字/时间行参与对齐，C1.5）
        → 名字/时间行：直接以 .metadata 状态输出，不翻译
        → 消息行：翻译。智能整理生效时，模型可能把某些行改判为 .metadata 或 .hidden
```

## 组件

### NoiseFilter（Kit，C1）

```swift
public enum LineRole: Sendable, Equatable { case message, metadata }

public struct NoiseFilter: Sendable {
    /// 返回 nil 表示丢弃（乱码行）
    public func classify(_ text: String, detectsMetadata: Bool) -> (text: String, role: LineRole)?
}
```

1. 移除界面标签（C1.2）：正则 `[（(]\s*(edited|已编辑|編集済み|수정됨)\s*[)）]`，忽略大小写，移除后用 `TextNormalizer.normalize` 重新整理空白。结果为空则丢弃。
2. 名字/时间行（C1.4，仅 `detectsMetadata == true`），先于乱码判断：
   - 时间正则（行尾）：`(?:[\[(]?(?:上午|下午|晚上|凌晨)?\s*\d{1,2}:\d{2}(?::\d{2})?\s*(?:[AaPp][Mm])?[\])]?)$`
   - 去掉时间后剩余部分按空白切词，词数 1–4（允许 0 个词，即整行只有时间）。
   - 剩余部分不含 `:`、`：`、`.`、`?`、`!`、`。`、`？`、`！`。
   - 第一个词的首字符是大写字母、数字、`@`、`#` 或非拉丁文字。
   - 实测数据：`Haka OGLUE 14:39`、`Archereon - Merc 14:40`、`Sanktas /idle 14:40` 判为名字行；`meet at 10:30`、`[14:39] Rex: gg` 判为消息。
3. 乱码行（C1.3）：统计 `Character.isLetter` 的字符（汉字、假名、韩文也算字母）。文字字符 < 2，或文字字符 / 非空白字符 < 0.25，丢弃。`gg`、`ok`、`S> 180K` 保留；`•`、`|| ::`、`1:1` 丢弃。

### 数据模型

- `Region` 新增两个字段，旧预设文件中没有这两个字段，用 `decodeIfPresent` 读取并取默认值（C1.1、C2.1）：
  - `filtersNoise: Bool`：默认 `mode == .chat`。
  - `smartCleanup: Bool`：默认 `true`。
- `TranslationState` 新增两个状态：
  - `.metadata`：名字/时间行，显示原文灰色小字，不翻译（C3.1）。
  - `.hidden`：界面文字，从面板移除（C2.3）。
- `TranslationProvider` 的单行结果从 `String` 改为 `TranslationOutput`：

  ```swift
  public enum TranslationOutput: Sendable, Equatable {
      case translated(String)
      case metadata
      case hidden
  }
  ```

  Google 只返回 `.translated`。

### 翻译请求（C2）

- `TranslationOptions` 和 `TranslationRequest` 新增 `classifiesLines: Bool`。流水线在 `smartCleanup && mode != .dialog` 时设为 `true`（C2.5）。Google provider 忽略该参数。
- 缓存键增加 `classifiesLines`，缓存值改为 `TranslationOutput`（C2.7）。批量合并的分组键也加上它，开关不同的请求不合并（提示词不同）。
- 提示词拆成两部分（C2.6）：
  - 规则部分：内置模板或用户自定义提示词。内置模板去掉原来的“只输出 JSON……”一句。
  - 输出格式部分：由 `PromptBuilder` 根据 `classifiesLines` 固定追加，用户不可修改。
    - 不标注：`{"translations": [{"id": 1, "text": "..."}]}`
    - 标注：`{"translations": [{"id": 1, "type": "message", "text": "..."}]}`，并说明 `type` 的取值：`message`（聊天消息或需要翻译的内容）、`name`（只有玩家名、频道、徽章、时间）、`ui`（按钮、标签、菜单或识别乱码）；`name` 和 `ui` 的 `text` 为空字符串。
- 内置模板变化会改变 fingerprint，旧缓存自然失效（缓存只在内存中）。
- `ResponseParser` 解析 `type`：`name` → `.metadata`，`ui` → `.hidden`，其他或缺失 → 按消息处理，需要有 `text`（C2.4）。
- 上下文只收集 `.done` 的消息行，`.metadata` 和 `.hidden` 不进入上下文（C2.8，现有逻辑已满足）。

### RegionPipeline

- 行组装后，`filtersNoise` 开启时调用 `NoiseFilter.classify(text, detectsMetadata: !smartCleanupActive)`。`smartCleanupActive` 由流水线配置提供：区域开启智能整理，且区域的翻译配置解析为 LLM（`PipelineConfiguration.usesLLM`，由 App 层根据翻译配置计算并在配置变化时更新）。
- 聊天去重对所有保留的行（消息 + 名字/时间）进行（C1.5）。
- 新条目中，名字/时间行直接以 `.metadata` 状态输出，不进入翻译。

### PanelHistory 与面板（C3）

- `apply(.append)` 返回的新增数只统计状态不是 `.metadata` 的行。
- `apply(.update(id, .hidden))` 删除该条目，返回 `-1`（如果该条目已计入未读，`PanelController` 将未读数减 1，最小为 0）（C3.2）。
- `plainText` 中 `.metadata` 行输出原文（C3.3）。
- `EntryRow`：`.metadata` 以 `fontSize × 0.8`、次要颜色显示原文，与下一条消息的间距更小，看起来像消息的标题。

### 区域配置界面

`RegionForm` 新增两个开关：“过滤界面噪声”和“智能整理（LLM）”，后者下方注明“仅在使用 LLM 翻译配置时生效”。框选后的快速配置窗口也显示这两个开关。

## 测试

- `NoiseFilter`：界面标签移除、乱码行判断、名字/时间行判断（含实测数据和反例）。
- `Region` 解码：旧预设文件（没有新字段）按模式取默认值。
- `PromptBuilder`：两种输出格式；自定义提示词后仍附加输出格式。
- `ResponseParser`：`type` 的三种取值、缺失、未知值。
- `TranslationService`：`classifiesLines` 不同的请求分开缓存、分开合并。
- `RegionPipeline`：规则过滤后的条目状态；智能整理返回 `.hidden` 时面板删除条目；名字/时间行参与去重对齐。
- `PanelHistory`：`.hidden` 删除、新增数不含 `.metadata`、复制全部。
- 用 `DiscordReplayTests` 的实测数据验证规则过滤后的结果。

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-10-24 | 初版 |
| 2026-10-24 | 实现时调整：名字/时间行先于乱码判断，乱码比例阈值改为 0.25；`ResponseParser.parse` 保留为只返回消息行的包装，新增 `parseOutputs`；provider 返回 `TranslationOutput` |
