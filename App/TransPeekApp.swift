import SwiftUI

/// 应用入口。TransPeek 是菜单栏应用（Info.plist 中 LSUIElement = YES），
/// 没有主窗口，界面由 AppDelegate 创建的菜单栏图标驱动。
@main
struct TransPeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 占位场景，设置界面在任务 15 中实现。
        Settings {
            EmptyView()
        }
    }
}
