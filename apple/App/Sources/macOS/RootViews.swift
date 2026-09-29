#if os(macOS)
import SwiftUI

/// 界面接入点：主窗口与菜单栏面板的根视图都在这里创建，界面实现替换这两处即可。
/// 视图通过环境取得 `AppServices`（`@Environment(AppServices.self)`）。
@MainActor
enum RootViews {
    static func mainWindow(_ services: AppServices) -> some View {
        PlaceholderView().environment(services)
    }

    static func menuBarPad(_ services: AppServices) -> some View {
        Text("菜单栏").padding().environment(services)
    }
}
#endif
