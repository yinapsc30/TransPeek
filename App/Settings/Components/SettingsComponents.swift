import SwiftUI
import TransPeekKit

extension Binding where Value == Double {
    /// 按步长取整。Slider 设置 `step` 时 macOS 会画一排刻度点，改用取整的 Binding。
    func rounded(to step: Double) -> Binding<Double> {
        Binding(get: { wrappedValue }, set: { wrappedValue = ($0 / step).rounded() * step })
    }
}

/// 页面容器：标题、说明、可滚动内容（S1.3）。
struct SettingsPage<Content: View>: View {
    let title: String
    var subtitle: String = ""
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.bold())
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                content
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 分组卡片：统一的中性背景，不使用彩色底框（S1.7）。行与行之间用 `SettingsDivider` 分隔。
struct SettingsCard<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider().padding(.leading, 14)
    }
}

/// 设置行：左侧标题和说明，右侧控件。说明文字在标题下方（S1.3）。
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    var error: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }
}

/// 按键样式（S8.1）。
struct KeyCap: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .frame(minWidth: 22, minHeight: 20)
            .padding(.horizontal, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

struct ShortcutKeys: View {
    let action: HotkeyAction

    var body: some View {
        HStack(spacing: 3) {
            KeyCap(symbol: "⌃")
            KeyCap(symbol: "⌥")
            KeyCap(symbol: action.keyEquivalent.uppercased())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Control Option \(action.keyEquivalent.uppercased())")
    }
}

/// 小圆点加文字的状态，颜色之外同时有文字（S11.1）。
struct StatusLabel: View {
    enum Tone { case ok, warning, problem, neutral }

    let text: String
    let tone: Tone

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var color: Color {
        switch tone {
        case .ok: .green
        case .warning: .orange
        case .problem: .red
        case .neutral: Color(nsColor: .tertiaryLabelColor)
        }
    }
}

extension StatusLabel {
    init(_ status: ServiceStatus) {
        let tone: Tone = switch status {
        case .passed: .ok
        case .missingKey, .missingModel, .failed: .problem
        case .testing: .neutral
        case .untested: .warning
        }
        self.init(text: status.label, tone: tone)
    }
}

/// 中性描边的小标签，例如“默认”（S1.7）。
struct OutlineTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// 侧边栏图标：彩色圆角方块里的白色符号。
struct PaneIcon: View {
    let pane: SettingsPane

    var body: some View {
        Image(systemName: pane.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(pane.color.gradient))
            .accessibilityHidden(true)
    }
}

/// 服务商图标：彩色方块加缩写，不使用服务商商标（S6.1）。
struct ProviderIcon: View {
    let presetID: String
    var size: CGFloat = 36

    private static let styles: [String: (Color, String)] = [
        "google": (Color(red: 0.26, green: 0.52, blue: 0.96), "G"),
        "openai": (Color(red: 0.06, green: 0.64, blue: 0.50), "AI"),
        "anthropic": (Color(red: 0.85, green: 0.47, blue: 0.34), "A"),
        "gemini": (Color(red: 0.11, green: 0.41, blue: 1.0), "Ge"),
        "deepseek": (Color(red: 0.30, green: 0.42, blue: 1.0), "DS"),
        "bailian": (Color(red: 1.0, green: 0.42, blue: 0.0), "百"),
        "moonshot": (Color(red: 0.09, green: 0.10, blue: 0.12), "K"),
        "zhipu": (Color(red: 0.23, green: 0.36, blue: 1.0), "智"),
        "openrouter": (Color(red: 0.39, green: 0.40, blue: 0.95), "OR"),
        "ollama": (Color(red: 0.11, green: 0.11, blue: 0.12), "Ol"),
        "lmstudio": (Color(red: 0.31, green: 0.27, blue: 0.90), "LM"),
    ]

    var body: some View {
        let style = Self.styles[presetID] ?? (Color.gray, "⋯")
        Text(style.1)
            .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24).fill(style.0.gradient))
            .accessibilityHidden(true)
    }
}

extension TranslationProfile {
    /// 用于图标的预设 ID。
    var iconID: String {
        llmConfig?.presetID ?? "google"
    }
}
