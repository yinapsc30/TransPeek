import SwiftUI
import TransPeekKit

/// 区域配置表单，框选完成后和区域管理中共用（R4.2、R4.5、R4.8）。
/// `extra` 显示在名称下方，用于选择所在面板（panel-groups G4.1、G4.6）。
struct RegionForm<Extra: View>: View {
    @Binding var region: Region
    let profiles: [TranslationProfile]
    var showsAdvanced = true
    let extra: Extra

    @State private var newPattern = ""

    init(region: Binding<Region>, profiles: [TranslationProfile], showsAdvanced: Bool = true, @ViewBuilder extra: () -> Extra) {
        _region = region
        self.profiles = profiles
        self.showsAdvanced = showsAdvanced
        self.extra = extra()
    }

    var body: some View {
        Form {
            TextField("名称", text: $region.name)
            extra
            Picker("模式", selection: $region.mode) {
                ForEach(RegionMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Text(modeHint).font(.caption).foregroundStyle(.secondary)

            Picker("源语言", selection: $region.sourceLanguage) {
                Text("自动检测").tag(Language?.none)
                ForEach(Language.all) { language in
                    Text(language.displayName).tag(Language?.some(language))
                }
            }
            Picker("目标语言", selection: $region.targetLanguage) {
                ForEach(Language.all) { language in
                    Text(language.displayName).tag(language)
                }
            }
            Picker("翻译配置", selection: $region.translationProfileID) {
                Text("全局默认").tag(UUID?.none)
                ForEach(profiles) { profile in
                    Text(profile.name).tag(UUID?.some(profile.id))
                }
            }

            Section("识别结果整理") {
                Toggle("过滤界面噪声", isOn: $region.filtersNoise)
                Text("去掉“(已编辑)”等界面标签和图标产生的乱码；名字和时间单独成行时用灰色小字显示，不翻译。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("智能整理（LLM）", isOn: $region.smartCleanup)
                Text("仅在使用 LLM 翻译配置时生效：由模型判断哪些是消息、哪些是名字或界面文字，只翻译消息，不增加请求次数。对话模式不使用。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if showsAdvanced {
                Section("忽略规则（正则表达式）") {
                    ForEach(Array(region.ignorePatterns.enumerated()), id: \.offset) { index, pattern in
                        HStack {
                            Text(pattern).font(.system(.body, design: .monospaced))
                            if !IgnoreRules.isValid(pattern) {
                                Text("无效").foregroundStyle(.red).font(.caption)
                            }
                            Spacer()
                            Button {
                                region.ignorePatterns.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("删除规则 \(pattern)")
                        }
                    }
                    HStack {
                        TextField("例如 \\bCH[O0]\\w{1,2}\\b", text: $newPattern)
                            .font(.system(.body, design: .monospaced))
                        Button("添加") {
                            region.ignorePatterns.append(newPattern)
                            newPattern = ""
                        }
                        .disabled(newPattern.isEmpty || !IgnoreRules.isValid(newPattern))
                    }
                    Text("翻译前移除匹配的文本，例如频道徽章、时间戳。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var modeHint: String {
        switch region.mode {
        case .once: "手动触发（⌃⌥R）时识别一次，适合物品说明、菜单。"
        case .dialog: "内容变化后替换当前显示，适合剧情对话框、字幕。"
        case .chat: "只追加新出现的行并保留历史，适合聊天频道、日志。"
        }
    }
}

/// 框选完成后弹出的区域配置（R4.2）。
struct RegionConfigView: View {
    @State var region: Region
    let profiles: [TranslationProfile]
    /// 当前目标窗口已有的面板（panel-groups G4.1）。
    let panelChoices: [PanelChoice]
    let currentGroupID: UUID?
    @State var destination: PanelDestination
    let onConfirm: (Region, PanelDestination) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            RegionForm(region: $region, profiles: profiles, showsAdvanced: false) {
                PanelDestinationPicker(
                    title: "显示在",
                    selection: $destination,
                    choices: panelChoices,
                    currentGroupID: currentGroupID
                )
            }
            Divider()
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("开始翻译") { onConfirm(region, destination) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(region.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 400)
    }
}

/// 选择区域显示在哪个面板（panel-groups G4.1、G4.6）。当前面板排在最前并标注。
struct PanelDestinationPicker: View {
    let title: String
    @Binding var selection: PanelDestination
    let choices: [PanelChoice]
    let currentGroupID: UUID?

    private var ordered: [PanelChoice] {
        choices.filter { $0.id == currentGroupID } + choices.filter { $0.id != currentGroupID }
    }

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(ordered) { choice in
                Text(choice.id == currentGroupID ? "当前面板（\(choice.name)）" : choice.name)
                    .tag(PanelDestination.group(choice.id))
            }
            Text("新面板").tag(PanelDestination.newPanel)
        }
    }
}
