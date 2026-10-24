# TransPeek

TransPeek 是一个开源的 macOS 窗口翻译工具。它截取你选择的应用窗口（或窗口里框选的区域），用 OCR 识别文字，再交给翻译服务，把译文显示在贴着窗口边缘的面板或悬浮窗里。适合没有本地化的游戏和软件，比如游戏的剧情对话、聊天频道、物品说明。

*TransPeek is an open-source macOS app that OCRs a window (or regions of it) and shows translations in a docked or floating panel. Built for games and apps without localization.*

## 功能

- 框选区域：按 ⌃⌥T 在目标窗口上框选要翻译的区域。区域按窗口的相对位置保存，窗口移动、缩放后自动跟随，并按应用自动保存为预设。
- 三种区域模式：
  - 单次：按 ⌃⌥R 时识别一次，适合物品说明、菜单。
  - 对话：内容变化后替换当前显示，适合剧情对话框、字幕。
  - 聊天：只追加新出现的行并保留历史，适合聊天频道、日志。
- 只在画面变化时识别，画面稳定后再识别，没有变化时几乎不占用资源。
- 面板两种形态，可以拖动互相切换：
  - 贴边：贴合窗口的上下左右任意一边，长度与窗口一致；窗口外没有空间（如全屏）时放在窗口内侧，半透明，可折叠成细边。
  - 悬浮：任意拖动和调整大小，跟随窗口移动。
- 贴边面板是毛玻璃样式，悬浮面板是几乎透明的字幕样式，尽量不挡游戏；按钮只在鼠标移到面板上时出现。聊天中识别出的名字显示为说话人标签。
- 多个区域可以合并到一个面板里，分栏显示（例如上面聊天、下面 NPC 对话）。拖动分隔条调整比例，每一栏可以单独折叠，折叠时继续翻译并显示新消息数。
- 面板不抢焦点，全屏游戏中也能显示；锁定（⌃⌥L）后鼠标穿透，不影响操作游戏。
- 翻译服务：Google Cloud Translation，以及 OpenAI、Anthropic（Claude）、Google Gemini、DeepSeek、阿里云百炼、Moonshot、智谱、OpenRouter、Ollama、LM Studio 或任意 OpenAI 兼容接口。每个区域可以单独选择翻译配置。
- 相同文本只翻译一次（内存缓存），多行合并成一次请求。

## 系统要求

- macOS 14.0 或更高版本
- 安装包只提供 Apple 芯片版本；Intel Mac 请从源码构建
- 从源码构建需要 Xcode 16 或更高版本、[XcodeGen](https://github.com/yonaskolb/XcodeGen)

## 安装

1. 从 Releases 下载 `TransPeek-x.y.z.zip`，解压后把 `TransPeek.app` 拖到“应用程序”文件夹。
2. 首次打开会被系统拦截（TransPeek 使用自签名证书，没有经过 Apple 公证）。任选一种方式放行：
   - 双击打开一次，然后到“系统设置 > 隐私与安全性”底部点“仍要打开”。
   - 或在终端执行：

     ```bash
     xattr -dr com.apple.quarantine /Applications/TransPeek.app
     ```

## 从源码构建

```bash
git clone <仓库地址> TransPeek
cd TransPeek
brew install xcodegen
Scripts/create_signing_cert.sh   # 只需运行一次：创建固定的自签名证书
Scripts/bundle.sh                # 输出 build/TransPeek.app
open build/TransPeek.app
```

`create_signing_cert.sh` 会创建名为 “TransPeek Self-Signed” 的代码签名证书，导入登录钥匙串，备份写到 `~/Documents/TransPeek-signing-backup/`，不会修改系统信任设置。之后每次 `bundle.sh` 都用它签名，重新构建后屏幕录制权限不会丢失。不创建证书也能打包，但会退回临时签名，每次重新构建都需要重新授权。

开发调试时可以用 Xcode：`xcodegen generate && open TransPeek.xcodeproj`，选择 TransPeek scheme 按 ⌘R。Xcode 中运行使用临时签名，与打包出来的 app 分别授权。

打发布用的 zip（会先运行测试，必须有证书）：

```bash
TRANSPEEK_VERSION=0.1.0 Scripts/release.sh   # 输出 build/TransPeek-0.1.0.zip 和 SHA-256
```

建议把 `TransPeek.app` 放到“应用程序”文件夹再使用，“开机时启动”在这个位置更可靠。

## 首次运行与权限

TransPeek 只需要一项权限：屏幕录制。

1. 首次启动会显示权限引导，点击“打开系统设置”，在“隐私与安全性 > 屏幕录制”中打开 TransPeek。
2. 授权后需要重启 TransPeek 才会生效（引导窗口中有“重启 TransPeek”按钮）。

如果授权后仍然无法截取（通常是换过签名，例如用临时签名重新构建过）：

1. 打开“系统设置 > 隐私与安全性 > 屏幕录制”。
2. 选中旧的 TransPeek 条目，点击“−”删除。
3. 重新启动 TransPeek，按提示重新授权。

## 使用

1. 切换到游戏或目标应用，按 ⌃⌥T，拖拽框选要翻译的区域（Esc 取消）。也可以先在菜单栏选择“选择目标窗口…”。
2. 在弹出的配置中选择区域模式、语言和翻译配置，点击“开始翻译”。
3. 面板默认贴在窗口右侧。鼠标移到面板上会出现按钮：“Aa”调整字号和显示原文，“⋯”是更多选项。拖动面板标题栏可以移动；拖到窗口某条边附近会出现蓝色预览，松开即贴边；从边缘拖开变成悬浮窗。

| 快捷键 | 功能 |
|---|---|
| ⌃⌥T | 框选新区域 |
| ⌃⌥R | 重新识别所有单次区域 |
| ⌃⌥P | 暂停/恢复所有区域 |
| ⌃⌥L | 锁定/解锁所有面板（锁定后鼠标穿透） |

小提示：

- 聊天区域尽量框大一些，能看到的行越多，刷屏时越不容易漏消息。真的漏了，面板中会出现“可能有遗漏”标记。
- 聊天区域默认开启“过滤界面噪声”：去掉“(已编辑)”等标签和图标乱码，名字行不翻译，显示为下一条消息的说话人。使用 LLM 翻译时还会开启“智能整理”，由模型判断哪些是消息，只翻译消息，不增加请求次数。两个开关都在“管理区域”中。
- 识别结果里还有固定的噪声（如频道徽章），可以在“管理区域”中给区域添加忽略规则（正则表达式），例如 `\bCH[O0]\w{1,2}\b`。
- 新框选的区域默认加入当前面板，在弹出的配置中可以改成“新面板”。之后可以在栏的“⋯”菜单中上移、下移、移到其他面板，或在“⋯”菜单的“面板”一节中“合并到”另一个面板；“管理区域”中也可以修改区域所在的面板。
- 关闭一栏等同于暂停该区域，关闭整个面板会暂停其中所有区域，在“管理区域”中可以恢复。

## 翻译服务

在“设置 > 翻译服务”中管理翻译配置，可以保存多个，设置一个默认配置。卡片上会显示每个服务是否可用（缺少 Key、未填模型、测试结果）。第一次使用可以先看“设置 > 开始使用”。

- Google 翻译：使用 [Cloud Translation API](https://cloud.google.com/translate/docs/setup)（Basic v2），需要你自己的 API Key。
- LLM：点“添加服务”选择服务商，自动填入 Base URL，再手动填写模型 ID（旁边的“查看模型列表”会打开服务商的模型文档）。温度、上下文条数、提示词和额外请求参数在“高级”中。保存前可以用“测试连接”验证当前填写的值。
- 本地模型：Ollama（`http://localhost:11434/v1`）和 LM Studio（`http://localhost:1234/v1`）不需要 API Key。只有本机和局域网地址允许使用 http，其他地址必须是 https。

游戏聊天刷新很快，LLM 建议选择非推理的快速模型。也可以给聊天区域用 Google、给剧情对话区域用 LLM。

## 隐私与数据流向

- 截图只在内存中处理，不保存到磁盘，不上传。
- 只有识别出的文字会发送给你选择的翻译服务；LLM 模式下还会附带该区域最近几条已翻译的文字作为上下文。使用本地模型时，文字不会离开你的电脑。
- API Key 保存在 macOS 钥匙串中，不写入配置文件，也不会出现在日志里。
- 译文历史只保存在内存中，退出后清除。
- TransPeek 不收集任何统计数据。
- 日志默认不包含识别出的文字。在“设置 > 隐私与数据”中开启“调试日志”后，识别文字会写入系统日志（subsystem `com.transpeek.app`）。

数据保存位置：

| 数据 | 位置 |
|---|---|
| 区域预设 | `~/Library/Application Support/TransPeek/presets/` |
| 翻译配置（不含 Key） | `~/Library/Application Support/TransPeek/translation-profiles.json` |
| 通用设置 | UserDefaults（`com.transpeek.app`） |
| API Key | 钥匙串（服务名 `com.transpeek.app`） |

## 费用

TransPeek 本身免费。翻译服务按各服务商的规则计费：Google Cloud Translation 和各家 LLM 都按用量收费，部分有免费额度，请以服务商官方定价页为准。TransPeek 通过缓存相同文本、只在画面变化时识别、合并请求来减少调用量。本地模型没有服务费用。

## 已知限制

- 只支持 macOS。
- 目标窗口最小化后无法截取；部分游戏被其他窗口完全遮挡时会停止渲染，此时画面不再更新。
- Apple Vision 对艺术字、像素字体、带描边特效的文字识别效果可能不理想。
- 部分全屏游戏使用独占显示模式时，面板可能无法显示在游戏上方，可以使用窗口化全屏。
- 快捷键暂不支持自定义；被其他应用占用时，菜单栏会提示冲突。

## 开发

```
App/                    # AppKit/SwiftUI：菜单栏、快捷键、截取、框选、面板、设置
Packages/TransPeekKit/  # 核心逻辑：变化检测、OCR、行组装、增量去重、翻译、布局计算、存储
Scripts/                # 证书创建、打包、发布
.kiro/specs/            # 需求、设计和任务文档
docs/manual-test.md     # 手动验收清单
```

运行核心逻辑的测试：

```bash
cd Packages/TransPeekKit
swift test
```

OCR 样例库在 `Packages/TransPeekKit/Tests/TransPeekKitTests/Fixtures/ocr/`，每个场景一个目录，包含 `image.png` 和 `expected.json`。欢迎提交更多游戏和应用的截图，新增场景不需要修改测试代码，格式见 `.kiro/specs/transpeek-mvp/design.md` 的“集成测试”一节。

LLM 服务商预设在 `Packages/TransPeekKit/Sources/TransPeekKit/Resources/LLMPresets.json`，服务商地址变化时欢迎提 PR。

## License

[MIT](LICENSE)
