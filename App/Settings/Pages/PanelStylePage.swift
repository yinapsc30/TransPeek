import SwiftUI
import TransPeekKit

/// 面板默认样式与实时预览（S5）。
struct PanelStylePage: View {
    @Bindable var settings: SettingsModel

    var body: some View {
        SettingsPage(title: SettingsPane.panel.title, subtitle: SettingsPane.panel.subtitle) {
            PanelPreview(
                fontSize: settings.settings.panelFontSize,
                opacity: settings.settings.panelOpacity,
                showsOriginal: settings.settings.defaultShowsOriginal
            )

            SettingsCard(title: "新面板默认样式", footer: "只用于新建的区域。已有面板可以在面板标题栏的菜单中单独调整。") {
                SettingsRow(title: "字号") {
                    HStack(spacing: 8) {
                        Text("A").font(.system(size: 11)).foregroundStyle(.secondary)
                        Slider(value: $settings.settings.panelFontSize.rounded(to: 1), in: PanelConfig.fontSizeRange)
                            .frame(width: 180)
                            .accessibilityLabel("字号")
                            .accessibilityValue("\(Int(settings.settings.panelFontSize)) 点")
                        Text("A").font(.system(size: 17)).foregroundStyle(.secondary)
                        Text("\(Int(settings.settings.panelFontSize)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    }
                }
                SettingsDivider()
                SettingsRow(title: "背景不透明度") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.settings.panelOpacity.rounded(to: 0.05), in: PanelConfig.opacityRange)
                            .frame(width: 214)
                            .accessibilityLabel("背景不透明度")
                        Text("\(Int((settings.settings.panelOpacity * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    }
                }
                SettingsDivider()
                SettingsRow(title: "默认位置", detail: "贴边时，窗口外侧放不下会自动换到对边或窗口内侧。") {
                    Picker("默认位置", selection: $settings.settings.defaultPanelPlacement) {
                        ForEach(DefaultPanelPlacement.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
                SettingsDivider()
                SettingsRow(title: "显示原文", detail: "在译文下方用小字显示识别出的原文。") {
                    Toggle("显示原文", isOn: $settings.settings.defaultShowsOriginal).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(title: "历史") {
                SettingsRow(title: "历史条目上限", detail: "每个面板最多保留的条目数，超出后丢弃最旧的。历史只保存在内存中。") {
                    Stepper(value: $settings.settings.historyLimit, in: AppSettings.historyLimitRange, step: 50) {
                        Text("\(settings.settings.historyLimit) 条").monospacedDigit()
                    }
                }
            }
        }
    }
}

/// 面板预览：并排显示贴边（HUD 玻璃）和悬浮（字幕）两种样式，不创建真实面板窗口（S5.1、panel-redesign P9）。
/// 使用与面板相同的组件（`PanelComponents.swift`）。
private struct PanelPreview: View {
    let fontSize: Double
    let opacity: Double
    let showsOriginal: Bool

    @State private var model = PanelPreviewModel()

    var body: some View {
        HStack(spacing: 10) {
            sample(title: "贴边", style: .hud)
            sample(title: "悬浮", style: .subtitle)
        }
        .frame(height: 220)
        .onAppear { model.apply(fontSize: fontSize, showsOriginal: showsOriginal) }
        .onChange(of: fontSize) { model.apply(fontSize: fontSize, showsOriginal: showsOriginal) }
        .onChange(of: showsOriginal) { model.apply(fontSize: fontSize, showsOriginal: showsOriginal) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("面板预览：贴边和悬浮两种样式")
    }

    private func sample(title: String, style: PanelStyle) -> some View {
        let section = model.section
        return ZStack(alignment: .topLeading) {
            // 模拟游戏画面
            LinearGradient(
                colors: [Color(red: 0.23, green: 0.35, blue: 0.25), Color(red: 0.48, green: 0.42, blue: 0.29), Color(red: 0.14, green: 0.20, blue: 0.29)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionTitleLabel(name: section.regionName, mode: section.mode, style: style)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: SectionLayout.headerSize)
                VStack(alignment: .leading, spacing: style == .hud ? 10 : 6) {
                    ForEach(section.displayItems) { item in
                        ChatItemRow(item: item, section: section, style: style)
                    }
                }
                .padding(.leading, style == .hud ? 6 : 12)
                .padding(.trailing, 12)
                Spacer(minLength: 0)
            }
            .background(PanelBackground(style: style, opacity: opacity, withinWindow: true))
            .clipShape(RoundedRectangle(cornerRadius: PanelBackground.cornerRadius))
            .shadow(color: .black.opacity(style == .hud ? 0.35 : 0), radius: 8, y: 4)
            .padding(14)
            .environment(\.colorScheme, .dark)

            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(.black.opacity(0.45)))
                .padding(6)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// 预览用的示例栏：名字行 + 消息，和真实面板一样经过说话人配对（P5）。
@MainActor
private final class PanelPreviewModel {
    let region = Region(name: "聊天区域", rect: CGRect(x: 0, y: 0, width: 1, height: 1), mode: .chat, targetLanguage: .simplifiedChinese)
    let section: SectionController

    init() {
        section = SectionController(region: region, historyLimit: 20)
        let id = region.id
        section.apply(.append([
            Entry(regionID: id, original: "Haka 14:39", translation: .metadata),
            Entry(regionID: id, original: "isnt it kinda hard to move around with low speed ._.", translation: .done("低速的时候是不是很难跑啊 ._.")),
            Entry(regionID: id, original: "Archereon 14:40", translation: .metadata),
            Entry(regionID: id, original: "I got a permit today", translation: .done("我今天拿到许可证了")),
        ]))
    }

    func apply(fontSize: Double, showsOriginal: Bool) {
        var region = region
        region.panel = PanelConfig(fontSize: fontSize, showsOriginal: showsOriginal)
        section.update(region: region)
    }
}
