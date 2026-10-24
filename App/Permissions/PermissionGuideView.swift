import SwiftUI

/// 权限引导窗口（R1.1、R1.2）。
struct PermissionGuideView: View {
    let permissions: PermissionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: permissions.screenCaptureGranted ? "checkmark.shield.fill" : "rectangle.dashed.badge.record")
                    .font(.system(size: 32))
                    .foregroundStyle(permissions.screenCaptureGranted ? .green : .accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("需要屏幕录制权限").font(.title2.bold())
                    Text(permissions.screenCaptureGranted ? "已授权，可以开始使用。" : "尚未授权")
                        .foregroundStyle(.secondary)
                }
            }

            Text("TransPeek 需要截取你选择的应用窗口，才能识别其中的文字并翻译。")
            VStack(alignment: .leading, spacing: 6) {
                Label("只截取你选择的窗口，不截取整个屏幕", systemImage: "macwindow")
                Label("截图只在内存中处理，不保存、不上传", systemImage: "lock")
                Label("只有识别出的文字会发送给你选择的翻译服务", systemImage: "text.bubble")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if permissions.mayNeedRestart || permissions.captureFailedDespiteGrant {
                Text("如果已经在系统设置中开启了 TransPeek，需要重启应用才能生效。")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 0)

            HStack {
                if permissions.mayNeedRestart || permissions.captureFailedDespiteGrant {
                    Button("重启 TransPeek") { permissions.relaunch() }
                }
                Spacer()
                Button("请求权限") { permissions.request() }
                    .disabled(permissions.screenCaptureGranted)
                Button("打开系统设置") { permissions.openSystemSettings() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 300)
    }
}
