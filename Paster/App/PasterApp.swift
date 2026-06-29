import SwiftUI

/// 应用入口。
///
/// Paster 是一个菜单栏常驻应用，主要交互由 `AppDelegate` 驱动（状态栏、热键、悬浮面板）。
/// 第 4 轮起，`Settings` 场景展示真正的设置界面（`SettingsView`）。
@main
struct PasterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}
