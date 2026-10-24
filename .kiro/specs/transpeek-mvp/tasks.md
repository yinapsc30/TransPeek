# TransPeek MVP 实现任务

按顺序执行，每个任务完成后都要能编译通过，`TransPeekKit` 的测试全部通过。先完成可单元测试的核心逻辑（任务 1–8），再做依赖真实窗口环境的 App 层（任务 9–16）。需求编号对应 `requirements.md`，设计细节见 `design.md`。

- [x] 1. 搭建工程骨架
  - 创建 `project.yml`（XcodeGen）：App target `TransPeek`，最低 macOS 14.0，Swift 6，ad-hoc 签名，关闭 App Sandbox，开启 Hardened Runtime
  - 创建 `Info.plist`：`LSUIElement`、`NSScreenCaptureUsageDescription`、`NSAppTransportSecurity.NSAllowsLocalNetworking`
  - 创建本地包 `Packages/TransPeekKit`（库 target + 测试 target），App target 依赖该包
  - 最小可运行的菜单栏应用：菜单栏图标 + “退出”菜单项
  - 添加 `LICENSE`（MIT）和 `.gitignore`（忽略生成的 `.xcodeproj`、`build/`、`.build/`）
  - 验证：`xcodegen generate`、`xcodebuild build`、`swift test` 都能成功
  - _需求：R2.1、R15.5、R15.6_

- [x] 2. 数据模型与存储
- [x] 2.1 实现核心数据模型
  - `Language`、`RegionMode`、`Region`、`PanelPlacement`、`PanelConfig`、`AppPreset`、`Entry`、`TranslationState`、`LLMProtocol`、`LLMConfig`、`TranslationProfile`
  - 测试：所有 Codable 模型的编码/解码往返
  - _需求：R4.3、R4.4、R9.5、R10.2、R16.5_
- [x] 2.2 实现 `PresetStore`
  - 按 Bundle ID 读写 `presets/<bundleID>.json`，带 `schemaVersion`；写入防抖 500ms
  - 文件损坏时备份为 `.corrupt` 并返回空预设
  - 测试：读写往返、损坏文件处理、防抖合并写入（注入时钟）
  - _需求：R4.7_
- [x] 2.3 实现 `KeychainStore`、`SettingsStore`、`TranslationProfileStore`
  - Keychain：Google Key（`google-api-key`）和 LLM Key（`llm-<profileID>`）的读、写、删除
  - `SettingsStore`：设置项读写和变更通知，默认值与需求一致
  - `TranslationProfileStore`：读写 `translation-profiles.json`，确保 Key 不写入文件
  - 测试：设置默认值、配置读写往返、序列化结果中不含 Key
  - _需求：R8.2、R13.1、R13.2、R16.7、R16.13_

- [x] 3. 文本处理
- [x] 3.1 实现 `Similarity` 和 `TextNormalizer`
  - 归一化编辑距离相似度；空白折叠、首尾孤立符号去除、全角空格统一；忽略正则过滤
  - 测试：相似度边界值、OCR 抖动样例（如 `GUTSs` 与 `GUTS`）、无效正则的处理
  - _需求：R4.8、R6.5、R7.2_
- [x] 3.2 实现 `LineAssembler`
  - 置信度过滤、按垂直重叠合并行、行内按 x 排序后以空格连接
  - 测试：用验证截图中的片段构造 fixture（名字 + 徽章 + 消息合成一行）、多行排序、低置信度过滤
  - _需求：R6.3、R6.4_
- [x] 3.3 实现 `LineDiffer` 和对话模式比较
  - 聊天模式：后缀/前缀对齐找新增行、向上翻看历史不产生新条目、无重叠时输出遗漏标记
  - 对话模式：整块文本相似度比较
  - 测试：滚动追加、无变化、翻看历史、无重叠、模糊匹配、真实的连续重复消息
  - _需求：R7.1–R7.5_

- [x] 4. OCR 引擎
  - 定义 `OCREngine` 协议和 `OCRFragment`；实现 `VisionOCREngine`（accurate 级别、语言设置、自动检测语言、坐标转换为左上原点）
  - 建立 OCR 样例库 `Fixtures/ocr/<场景>/`（`image.png` + `expected.json`），先放入 `pic/` 中的两张图
  - 数据驱动的集成测试：遍历所有场景，`VisionOCREngine` + `LineAssembler` 识别后校验 `mustContain`，失败时列出实际识别的所有行，结束后输出耗时汇总
  - _需求：R6.1、R6.2、R6.6、R14.1_

- [x] 5. 变化检测
- [x] 5.1 实现 `ChangeDetector`
  - 用 vImage 缩放到宽 128px 的灰度图，计算与基准图的平均绝对差
  - 测试：完全相同、轻微噪声、明显变化、尺寸变化
  - _需求：R5.3_
- [x] 5.2 实现 `StabilityGate`
  - 稳定 250ms 放行；持续变化 1s 强制放行；时间通过注入的时钟控制
  - 测试：稳定放行、持续变化时强制放行、放行后状态重置
  - _需求：R5.4_

- [x] 6. 翻译
- [x] 6.1 实现翻译接口和缓存
  - `TranslationRequest`、`TranslationProvider`（含 `fingerprint`）、`TranslationResult`；`TranslationCache`（LRU，5000 条）
  - 测试：命中、淘汰、不同 fingerprint 互不影响
  - _需求：R8.4、R8.7_
- [x] 6.2 实现 `Batcher` 和 `TranslationService`
  - 按（配置、源语言、目标语言）分组合并；Google 和 LLM 使用不同的合并窗口、批量上限和并发上限；同文本并发请求合并
  - 按区域配置或全局默认选择 provider；配置变化后重建 provider
  - 可重试错误的指数退避重试；失败时回退到 Google 并标记
  - 测试（mock provider + 注入时钟）：缓存命中不发请求、批量合并、并发去重、重试次数和间隔、不可重试错误、回退
  - _需求：R8.4–R8.6、R16.7、R16.12_
- [x] 6.3 实现 `GoogleTranslateProvider`
  - v2 REST 请求、`format: text`、自动检测语言时不传 `source`；未配置 Key 时返回不可用
  - 测试（`URLProtocol` mock）：请求格式、响应解析、400/403/429/5xx 映射
  - _需求：R8.1、R8.3_
- [x] 6.4 实现 LLM 服务商预设和 Base URL 校验
  - 编写 `LLMPresets.json`（11 个预设：协议、Base URL、是否需要 Key、模型文档链接、是否支持 JSON 模式），逐一对照官方文档核对 Base URL 和文档链接
  - 实现预设加载器和 Base URL 校验（本机/局域网允许 http，其余必须 https）
  - 测试：预设文件解码、字段完整；各类地址的校验结果
  - _需求：R16.1、R16.3、R16.4_
- [x] 6.5 实现 `OpenAICompatibleClient` 和 `AnthropicClient`
  - 请求头、请求体、`max_tokens` 估算、JSON 输出模式、额外请求参数浅合并（用户参数优先）
  - 测试（`URLProtocol` mock）：两种协议的请求和响应、额外参数合并、错误码映射（含模型 ID 错误的提示）
  - _需求：R8.8、R16.2、R16.10_
- [x] 6.6 实现 `PromptBuilder` 和 `ResponseParser`
  - 内置 system 提示词模板和变量替换；user 消息组装（上下文 + 编号行）
  - 解析：去代码块标记、按 id 对应、收集缺失行
  - 测试：变量替换、上下文截断、标准输出、带代码块、条数不匹配、id 缺失/重复、无法解析
  - _需求：R16.6、R16.8、R16.9_
- [x] 6.7 实现 `LLMTranslationProvider`
  - 组合 PromptBuilder、LLMClient 和 ResponseParser；缺失行逐行重试一次；计算 fingerprint
  - 测试：正常批量、部分行逐行重试、仍失败时标记失败、fingerprint 随配置变化
  - _需求：R16.8、R16.11_

- [x] 7. 区域处理流水线
  - 实现 `RegionPipeline` actor：裁剪 → 变化检测 → 稳定判定 → OCR → 行组装 → 按模式处理 → 翻译 → 输出条目
  - OCR 进行中只保留最新的待处理帧；全局 OCR 并发上限 2；“单次”模式按需触发
  - 聊天模式把最近 N 条已翻译条目作为上下文；历史条目上限
  - 关键阶段加 `os_signpost`，用于性能测量
  - 测试（fake OCR 引擎 + mock 翻译 + 合成帧）：三种模式的输出、无变化时不调用 OCR、帧合并、遗漏标记、历史上限
  - _需求：R4.3、R5.3–R5.5、R7.6、R14.3、R16.9_

- [x] 8. 面板布局计算
- [x] 8.1 实现 `DockLayoutCalculator`
  - 四个方向的外侧候选 frame、外侧空间不足时切换为内侧、折叠时的厚度
  - 测试：四个方向、贴近屏幕边缘、窗口铺满屏幕、多屏
  - _需求：R9.1–R9.3、R12.2_
- [x] 8.2 实现 `SnapDetector`
  - 拖动时返回吸附候选边；判断贴边面板是否被拖离
  - 测试：各边阈值内外、角落同时靠近两条边时的选择
  - _需求：R10.3、R10.4_

- [x] 9. 权限与菜单栏
- [x] 9.1 实现 `PermissionManager` 和权限引导窗口
  - 检查和请求屏幕录制权限、跳转系统设置、回到前台时重新检查、提示重启
  - 权限缺失时禁用截取相关菜单并显示状态
  - _需求：R1.1–R1.4_
- [x] 9.2 实现 `MenuBarController` 和 `HotkeyManager`
  - 菜单栏菜单的所有菜单项（暂未实现的功能先禁用）
  - Carbon 全局快捷键注册 4 个默认快捷键，注册冲突时在菜单中提示
  - _需求：R2.1–R2.4_

- [x] 10. 窗口选择与跟踪
- [x] 10.1 实现窗口选择
  - `SCShareableContent` 获取窗口列表并过滤，生成缩略图，SwiftUI 选择界面
  - 未选择目标窗口时，按快捷键使用前台应用的最前窗口
  - _需求：R3.1、R3.2_
- [x] 10.2 实现 `PollingWindowTracker` 和 `ScreenGeometry`
  - 30Hz 轮询窗口位置和 `isOnScreen`，只在变化时发出事件；窗口消失时发出关闭事件
  - CG 坐标与 Cocoa 坐标转换（多屏）
  - _需求：R3.4–R3.6、R12.3_

- [x] 11. 截取服务
  - 实现 `CaptureService`：每个窗口一个 `SCStream`（按窗口过滤、原始分辨率、采样频率）；只有单次区域时用 `SCScreenshotManager`
  - 窗口尺寸变化时更新配置；窗口不在屏幕上时停止，恢复后重建；意外停止时按设计重试
  - 帧分发给对应窗口的各个 `RegionPipeline`
  - _需求：R3.5、R3.7、R5.1、R5.2、R5.6_

- [x] 12. 区域框选
  - 实现 `RegionSelectorWindow`：遮罩、拖拽绘制、限制在目标窗口内、Esc 取消、换算归一化坐标
  - 实现 `RegionConfigView`：名称、模式、源语言、目标语言、翻译配置，带默认值
  - 支持对已有区域重新框选
  - _需求：R4.1、R4.2、R4.6_

- [x] 13. 面板
- [x] 13.1 实现 `TranslationPanel`
  - NSPanel 配置：不抢焦点、全屏辅助、所有桌面可见、浮动层级；锁定时鼠标穿透并弱化标题栏
  - _需求：R11.5、R11.6、R12.1_
- [x] 13.2 实现 `PanelContentView`
  - 条目视图（译文、原文、显示原文开关、失败标记和手动重试、“已回退”标注）、遗漏标记分隔线
  - 自动滚动、“↓ N 条新消息”按钮、对话模式顶部固定当前文本
  - 字号、右键菜单（复制译文、复制原文、复制全部、清空历史）、精简模式
  - _需求：R8.6、R10.6、R11.1–R11.4、R16.12_
- [x] 13.3 实现 `PanelController` 和 `PanelManager`
  - 贴边模式：调用 `DockLayoutCalculator` 跟随窗口；内侧模式半透明、折叠和悬停展开
  - 悬浮模式：拖动、缩放、相对窗口偏移跟随；吸附预览和模式切换；透明度
  - 跟随窗口显示/隐藏；配置变化写回预设
  - _需求：R9.1–R9.5、R10.1–R10.5、R3.5、R12.3_

- [x] 14. 会话串联与区域管理
  - 实现 `SessionCoordinator`：选择窗口 → 加载预设 → 创建流水线和面板 → 启动截取；窗口关闭时停止并保留面板历史
  - 接入快捷键和菜单命令：框选、锁定/解锁、暂停/恢复全部、重新识别单次区域
  - 区域管理界面：重命名、修改模式/语言/翻译配置/忽略规则、暂停、删除、重新框选；关闭面板等同于暂停区域
  - _需求：R2.3、R3.3、R3.6、R4.5、R4.7、R11.7_

- [x] 15. 设置界面
- [x] 15.1 实现通用设置
  - 默认语言、默认翻译配置、采样频率、OCR 置信度阈值、历史上限、面板字号和透明度、开机启动（`SMAppService`），修改后立即生效
  - _需求：R13.1、R13.2_
- [x] 15.2 实现翻译配置管理
  - 配置列表：新增、删除、重命名、设为默认
  - Google 配置：API Key 输入和“测试翻译”
  - LLM 配置编辑：选择预设自动填充、Base URL 校验、模型 ID 手动输入和文档链接、Key、温度、上下文条数、提示词、额外请求参数（JSON 校验）、回退开关、“测试连接”（显示译文、耗时或错误）
  - _需求：R8.3、R13.3、R16.1、R16.3–R16.6、R16.10–R16.13_

- [x] 16. 隐私、文档与 CI
  - 统一用 `os.Logger`：识别文本标记为 private，确保任何日志都不输出 API Key；调试模式开关
  - 编写 README：功能介绍、从源码构建的步骤、权限用途、ad-hoc 签名重新授权的方法、数据流向、翻译服务费用说明
  - 编写 `docs/manual-test.md`：遮挡截取、最小化暂停、全屏、切换桌面、鼠标穿透、不抢焦点、性能指标测量方法
  - 添加 GitHub Actions：`swift test` 和 `xcodebuild build`
  - _需求：R14.1–R14.4、R15.1–R15.4、R15.6_

- [x] 17. 打包与安装包
  - 编写 `Scripts/create_signing_cert.sh`：创建并导入 “TransPeek Self-Signed” 证书，备份到 `~/Documents/TransPeek-signing-backup/`
  - 编写 `Scripts/bundle.sh`：Release、arm64 构建，输出 `build/TransPeek.app`，有证书时用证书签名，否则退回 ad-hoc 并提示
  - 编写 `Scripts/release.sh`：要求证书 → 测试 → 打包 → 生成 zip 和 SHA-256
  - README 增加安装包的安装和首次打开放行说明，更新从源码构建的步骤
  - 验证：创建证书、打包、签名校验通过、架构为 arm64、应用能启动；重新打包后签名的证书不变
  - _需求：R15.5、R15.6、R15.7_

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-10-24 | 初版 |
| 2026-10-24 | 任务 4 改为数据驱动的 OCR 样例库测试 |
| 2026-10-24 | 完成任务 1 |
| 2026-10-24 | 完成任务 2–8（TransPeekKit 核心逻辑，120 个单元测试 + OCR 样例库测试通过） |
| 2026-10-24 | 完成任务 9–16 的代码（App 层、README、手动验收清单、CI）；新增流水线集成测试（Vision + 样例截图）。`docs/manual-test.md` 中依赖真实窗口环境的验收项尚未执行，需要在授予屏幕录制权限后手动验证 |
| 2026-10-24 | 新增任务 17（打包与安装包） |
| 2026-10-24 | 完成任务 17：创建证书、打包、发布 zip 均已验证；重新打包后签名身份不变 |
| 2026-10-24 | 试用反馈修复（R8.9、R9.2、R10.1、R14.5）：中文不翻译、外侧放置回退顺序、AppKit 层调整大小、OCR 预热；新增 12 个单元测试 |
