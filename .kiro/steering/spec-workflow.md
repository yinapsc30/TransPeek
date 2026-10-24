# 开发流程：Spec 驱动

本项目（TransPeek）所有功能开发都遵循 spec 流程，spec 文档存放在 `.kiro/specs/<feature>/`。

## 规则

1. 新功能：先创建或更新 spec，按 requirements.md → design.md → tasks.md 的顺序推进。每个阶段都要经过用户确认，再进入下一阶段。
2. 修改已有功能：先更新相关 spec 的 requirements.md、design.md、tasks.md，用户确认后再改代码。不实现 spec 中没有写的行为。
3. 实现过程中如果发现设计需要调整（例如 API 限制、实测结果不符合预期），先停下来更新 design.md 并说明原因，再继续。
4. 每次更新 spec 文档，都要在文档末尾的“变更记录”表格中追加一行，写明日期和变更内容。
5. 需求编号（如 R5.4）在 design.md 和 tasks.md 中保持引用，方便追溯；已发布的需求编号不要重新编号，废弃的需求标注“已废弃”。
6. 范围外的想法记录到相关 requirements.md 的“范围外”一节，不直接实现。

## 项目约定

- 文档使用中文。
- 平台：仅 macOS 14.0+，Swift 6，SwiftUI + AppKit。
- 引入第三方依赖前，需要先在 design.md 中说明理由并经用户确认。
- 核心逻辑放在 `Packages/TransPeekKit`，保证能用 `swift test` 测试。
