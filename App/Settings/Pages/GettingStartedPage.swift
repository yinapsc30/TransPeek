import SwiftUI
import TransPeekKit

/// 开始使用：三个步骤及其实时状态（S2）。
struct GettingStartedPage: View {
    let context: SettingsContext

    private var permissions: PermissionManager { context.services.permissions }
    private var progress: SetupProgress { context.setup.progress }

    var body: some View {
        SettingsPage(title: SettingsPane.gettingStarted.title, subtitle: progress.pendingCount == 0 ? "都准备好了。" : SettingsPane.gettingStarted.subtitle) {
            SettingsCard {
                StepRow(number: 1, title: "屏幕录制权限", done: progress.permissionGranted,
                        detail: progress.permissionGranted ? "已授权" : permissionDetail) {
                    if !progress.permissionGranted {
                        HStack {
                            if permissions.mayNeedRestart || permissions.captureFailedDespiteGrant {
                                Button("重启 TransPeek") { permissions.relaunch() }
                            }
                            Button("打开系统设置") { permissions.openSystemSettings() }
                        }
                    }
                }
                SettingsDivider()
                StepRow(number: 2, title: "配置翻译服务", done: progress.serviceConfigured,
                        detail: progress.serviceConfigured ? serviceName : "还没有可用的翻译服务，识别结果只会显示原文。",
                        showsActionWhenDone: true) {
                    Button(progress.serviceConfigured ? "管理" : "配置翻译服务") { openDefaultService() }
                }
                SettingsDivider()
                StepRow(number: 3, title: "框选第一个区域", done: progress.hasRegion, detail: nil) {
                    Button("选择目标窗口") { context.actions.showWindowPicker() }
                }
                if !progress.hasRegion {
                    HStack(spacing: 4) {
                        Text("切换到游戏或应用，按")
                        ShortcutKeys(action: .selectRegion)
                        Text("拖拽框选要翻译的区域。")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 52)
                    .padding(.bottom, 12)
                }
            }

            SettingsCard(title: "当前") {
                SettingsRow(title: "目标窗口", detail: context.coordinator.target?.displayTitle ?? "未选择") {
                    Button("选择…") { context.actions.showWindowPicker() }
                }
                SettingsDivider()
                SettingsRow(title: "区域", detail: regionSummary) {
                    Button("管理区域…") { context.actions.showRegionManager() }
                }
            }
        }
    }

    private var permissionDetail: String {
        if permissions.mayNeedRestart || permissions.captureFailedDespiteGrant {
            return "如果已经在系统设置中开启了 TransPeek，需要重启应用才能生效。"
        }
        return "用于截取你选择的窗口。截图只在内存中处理，不保存、不上传。"
    }

    private var serviceName: String {
        guard let profile = context.services.profiles.resolve(nil, defaultID: context.settings.settings.defaultProfileID) else { return "" }
        return "默认：\(profile.name)"
    }

    private var regionSummary: String {
        let regions = context.coordinator.regions
        guard !regions.isEmpty else { return context.coordinator.target == nil ? "—" : "还没有区域" }
        let paused = regions.filter(\.isPaused).count
        return paused > 0 ? "\(regions.count) 个（\(paused) 个已暂停）" : "\(regions.count) 个"
    }

    private func openDefaultService() {
        if let id = context.defaultProfileID {
            context.router.openService(.existing(id))
        } else {
            context.router.select(.services)
        }
    }
}

private struct StepRow<Action: View>: View {
    let number: Int
    let title: String
    let done: Bool
    let detail: String?
    var showsActionWhenDone = false
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                if done {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(.green)
                } else {
                    Circle().strokeBorder(Color(nsColor: .tertiaryLabelColor), lineWidth: 1.5).frame(width: 22, height: 22)
                    Text("\(number)").font(.caption.bold()).foregroundStyle(.secondary)
                }
            }
            .frame(width: 24)
            .accessibilityLabel(done ? "已完成" : "第 \(number) 步，未完成")
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            if !done || showsActionWhenDone { action }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
