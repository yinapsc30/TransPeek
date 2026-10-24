import SwiftUI
import TransPeekKit

/// 设置窗口：左侧导航，右侧当前页面（S1.1）。
struct SettingsRootView: View {
    let context: SettingsContext
    @Bindable private var router: SettingsRouter

    init(context: SettingsContext) {
        self.context = context
        router = context.router
    }

    var body: some View {
        // 侧边栏用自绘按钮实现：NavigationSplitView + List(selection:) 在这个窗口中点击无反应（用户实测），
        // 自绘按钮保证可以点击，选中样式也只有蓝底（S1.7）。
        HStack(spacing: 0) {
            SettingsSidebar(router: router, pendingCount: context.setup.progress.pendingCount)
                .frame(width: 200)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 820, minHeight: 560)
        // 选中项和主要按钮固定用蓝色，不跟随系统强调色（S1.7）
        .tint(Color(nsColor: .systemBlue))
        .onAppear {
            context.services.permissions.refresh()
            context.setup.refresh()
        }
        .alert(
            "有未保存的修改",
            isPresented: Binding(get: { router.pendingAction != nil }, set: { if !$0 { router.resolvePending(save: nil) } }),
            presenting: router.pendingAction
        ) { _ in
            Button("保存") { router.resolvePending(save: true) }
                .keyboardShortcut(.defaultAction)
            Button("放弃修改", role: .destructive) { router.resolvePending(save: false) }
            Button("取消", role: .cancel) { router.resolvePending(save: nil) }
        } message: { _ in
            Text("离开前要保存对翻译服务的修改吗？")
        }
    }

    @ViewBuilder
    fileprivate var detail: some View {
        switch router.pane {
        case .gettingStarted: GettingStartedPage(context: context)
        case .general: GeneralPage(context: context, settings: context.settings, launchAtLogin: context.launchAtLogin)
        case .recognition: RecognitionPage(settings: context.settings)
        case .panel: PanelStylePage(settings: context.settings)
        case .services:
            if let route = router.serviceRoute {
                ServiceEditorPage(context: context, route: route).id(route)
            } else {
                TranslationServicesPage(context: context)
            }
        case .hotkeys: HotkeysPage(conflicts: context.hotkeyConflicts())
        case .privacy: PrivacyPage(settings: context.settings)
        case .about: AboutPage()
        }
    }
}

/// 侧边栏：点击切换页面，获得焦点后可以用上下方向键切换（S1.1、S11.2）。
private struct SettingsSidebar: View {
    let router: SettingsRouter
    let pendingCount: Int
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPane.allCases) { pane in
                SidebarRow(pane: pane, isSelected: router.pane == pane, badge: pane == .gettingStarted ? pendingCount : 0) {
                    router.select(pane)
                    isFocused = true
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            let panes = SettingsPane.allCases
            guard let index = panes.firstIndex(of: router.pane) else { return }
            switch direction {
            case .up where index > 0: router.select(panes[index - 1])
            case .down where index < panes.count - 1: router.select(panes[index + 1])
            default: break
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("设置分类")
    }
}

private struct SidebarRow: View {
    let pane: SettingsPane
    let isSelected: Bool
    let badge: Int
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                PaneIcon(pane: pane)
                Text(pane.title)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption2.bold())
                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                        .accessibilityLabel("\(badge) 项未完成")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color(nsColor: .systemBlue) : (isHovering ? Color.primary.opacity(0.06) : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
