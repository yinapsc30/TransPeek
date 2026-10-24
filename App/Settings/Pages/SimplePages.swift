import AppKit
import SwiftUI
import TransPeekKit

// MARK: - 通用（S3）

struct GeneralPage: View {
    let context: SettingsContext
    @Bindable var settings: SettingsModel
    let launchAtLogin: LaunchAtLogin

    var body: some View {
        SettingsPage(title: SettingsPane.general.title, subtitle: SettingsPane.general.subtitle) {
            SettingsCard(title: "语言", footer: "新建区域时使用这里的语言，每个区域可以单独修改。") {
                SettingsRow(title: "源语言", detail: "游戏或应用中文字的语言。不确定时选“自动检测”。") {
                    Picker("源语言", selection: $settings.settings.defaultSourceLanguage) {
                        Text("自动检测").tag(Language?.none)
                        Divider()
                        ForEach(Language.all) { Text($0.displayName).tag(Language?.some($0)) }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
                SettingsDivider()
                SettingsRow(title: "目标语言", detail: "翻译成的语言。") {
                    HStack(spacing: 8) {
                        Button {
                            swapLanguages()
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(settings.settings.defaultSourceLanguage == nil)
                        .help(settings.settings.defaultSourceLanguage == nil ? "源语言为“自动检测”时不能交换" : "交换源语言和目标语言")
                        .accessibilityLabel("交换源语言和目标语言")
                        Picker("目标语言", selection: $settings.settings.defaultTargetLanguage) {
                            ForEach(Language.all) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                }
            }

            SettingsCard(title: "启动") {
                SettingsRow(title: "开机时启动", detail: launchAtLogin.errorMessage) {
                    Toggle("开机时启动", isOn: Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.set($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
        }
    }

    private func swapLanguages() {
        guard let source = settings.settings.defaultSourceLanguage else { return }
        let target = settings.settings.defaultTargetLanguage
        settings.settings.defaultSourceLanguage = target
        settings.settings.defaultTargetLanguage = source
    }
}

// MARK: - 识别（S4）

struct RecognitionPage: View {
    @Bindable var settings: SettingsModel

    private enum FPSPreset: String, CaseIterable, Identifiable {
        case power, balanced, timely, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .power: "省电"
            case .balanced: "均衡"
            case .timely: "及时"
            case .custom: "自定义"
            }
        }
        var fps: Int? {
            switch self {
            case .power: 2
            case .balanced: 4
            case .timely: 8
            case .custom: nil
            }
        }
        static func matching(_ fps: Int) -> FPSPreset {
            allCases.first { $0.fps == fps } ?? .custom
        }
    }

    @State private var preset: FPSPreset = .balanced

    var body: some View {
        SettingsPage(title: SettingsPane.recognition.title, subtitle: SettingsPane.recognition.subtitle) {
            SettingsCard(title: "采样频率", footer: "画面没有变化时不会识别，所以频率主要影响新内容出现到开始识别的延迟。") {
                SettingsRow(title: "截取频率", detail: fpsDetail) {
                    Picker("截取频率", selection: $preset) {
                        ForEach(FPSPreset.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    .onChange(of: preset) { _, newValue in
                        if let fps = newValue.fps { settings.settings.sampleFPS = fps }
                    }
                }
                if preset == .custom {
                    SettingsDivider()
                    SettingsRow(title: "自定义频率") {
                        Stepper(value: $settings.settings.sampleFPS, in: AppSettings.sampleFPSRange) {
                            Text("\(settings.settings.sampleFPS) 帧/秒").monospacedDigit()
                        }
                    }
                }
            }

            SettingsCard(title: "文字识别", footer: "低于阈值的识别片段会被丢弃。识别结果噪声多时调高，漏字多时调低。") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("置信度阈值")
                        Spacer()
                        Text(settings.settings.ocrConfidenceThreshold, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Text("更少漏字").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $settings.settings.ocrConfidenceThreshold.rounded(to: 0.05), in: 0...0.9)
                            .labelsHidden()
                            .accessibilityLabel("置信度阈值")
                        Text("更少噪声").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
            }
        }
        .onAppear { preset = .matching(settings.settings.sampleFPS) }
    }

    private var fpsDetail: String {
        switch preset {
        case .power: "每秒 2 帧。适合剧情对话这类不常变化的内容，占用最低。"
        case .balanced: "每秒 4 帧。适合大多数聊天频道。"
        case .timely: "每秒 8 帧。适合刷屏很快的聊天，占用略高。"
        case .custom: "每秒 1–10 帧。"
        }
    }
}

// MARK: - 快捷键（S8）

struct HotkeysPage: View {
    let conflicts: [HotkeyAction]

    var body: some View {
        SettingsPage(title: SettingsPane.hotkeys.title, subtitle: SettingsPane.hotkeys.subtitle) {
            SettingsCard(footer: conflicts.isEmpty ? "暂不支持自定义快捷键。" : "被占用的快捷键按下时不会触发 TransPeek，可以在菜单栏菜单中执行对应的操作。暂不支持自定义快捷键。") {
                ForEach(Array(HotkeyAction.allCases.enumerated()), id: \.element) { index, action in
                    if index > 0 { SettingsDivider() }
                    SettingsRow(title: action.displayName, detail: detail(for: action),
                                error: conflicts.contains(action) ? "已被其他应用占用" : nil) {
                        ShortcutKeys(action: action)
                    }
                }
            }
        }
    }

    private func detail(for action: HotkeyAction) -> String {
        switch action {
        case .selectRegion: "在当前窗口上拖拽框选要翻译的区域。"
        case .toggleLock: "锁定后面板不响应鼠标，点击会直接落到下方的窗口。"
        case .togglePause: "暂停或恢复所有区域的识别。"
        case .rerunOnce: "对所有“单次”模式的区域重新识别一次。"
        }
    }
}

// MARK: - 隐私与数据（S9）

struct PrivacyPage: View {
    @Bindable var settings: SettingsModel

    var body: some View {
        SettingsPage(title: SettingsPane.privacy.title, subtitle: SettingsPane.privacy.subtitle) {
            SettingsCard(title: "数据流向") {
                ForEach(Array(Self.facts.enumerated()), id: \.offset) { index, fact in
                    if index > 0 { SettingsDivider() }
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: fact.symbol).foregroundStyle(.secondary).frame(width: 20).accessibilityHidden(true)
                        Text(fact.text).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }

            SettingsCard(title: "保存位置", footer: "API Key 保存在“钥匙串访问”中，服务名为 com.transpeek.app。") {
                SettingsRow(title: "区域预设", detail: AppPaths.presets.path) {
                    Button("在访达中显示") { reveal(AppPaths.presets, isDirectory: true) }
                }
                SettingsDivider()
                SettingsRow(title: "翻译配置（不含 API Key）", detail: AppPaths.translationProfiles.path) {
                    Button("在访达中显示") { reveal(AppPaths.translationProfiles, isDirectory: false) }
                }
            }

            SettingsCard(title: "排查问题") {
                SettingsRow(title: "调试日志", detail: "开启后，识别出的文字会写入系统日志（subsystem：com.transpeek.app），便于排查问题。日志中永远不包含 API Key。") {
                    Toggle("调试日志", isOn: $settings.settings.debugLogging).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }

    private static let facts: [(symbol: String, text: String)] = [
        ("macwindow", "只截取你选择的窗口，截图只在内存中处理，不保存到磁盘，不上传。"),
        ("text.bubble", "只有识别出的文字会发送给你选择的翻译服务；LLM 模式下还会附带该区域最近几条已翻译的文字作为上下文。"),
        ("desktopcomputer", "使用 Ollama、LM Studio 等本地模型时，文字不会离开你的电脑。"),
        ("key", "API Key 保存在 macOS 钥匙串中，不写入配置文件，也不会出现在日志里。"),
        ("clock.arrow.circlepath", "译文历史只保存在内存中，退出后清除。TransPeek 不收集任何统计数据。"),
    ]

    private func reveal(_ url: URL, isDirectory: Bool) {
        let directory = isDirectory ? url : url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(directory)
        }
    }
}

// MARK: - 关于（S10）

struct AboutPage: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "版本 \(short)（\(build)）"
    }

    var body: some View {
        SettingsPage(title: SettingsPane.about.title) {
            SettingsCard {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TransPeek").font(.title3.bold())
                        Text(version).foregroundStyle(.secondary)
                        Text("截取窗口文字并翻译，适合没有本地化的游戏和软件。").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(16)
                SettingsDivider()
                SettingsRow(title: "开源协议", detail: "MIT License") { EmptyView() }
                SettingsDivider()
                SettingsRow(title: "签名", detail: "使用自签名证书 “TransPeek Self-Signed” 签名，未经 Apple 公证。") { EmptyView() }
            }
        }
    }
}
