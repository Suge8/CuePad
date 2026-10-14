#if os(macOS)
import AppKit
import SwiftUI

/// 界面接入点：主窗口与菜单栏面板的根视图都在这里创建。
/// 视图通过环境取得 `AppServices`（`@Environment(AppServices.self)`）与本窗口的 `Workspace`。
enum RootViews {
    static func mainWindow(_ services: AppServices, workspace: Workspace) -> some View {
        MainRoot(workspace: workspace).environment(services)
    }

    /// 设置窗口（⌘, 与菜单"设置…"）的内容。
    static func settings(_ services: AppServices, cueBar: CueBar) -> some View {
        SettingsView()
            .environment(cueBar)
            .panelHost()
            .modifier(PaletteProvider())
            .environment(services)
    }

    /// 面板与主窗口共用 App 常驻的那个工作区（项目目录、会话归属与摘要只订阅一份，见 `Workspace.follow`）。
    /// `open`：在主窗口里打开一页（会话、Cue 页；面板自己不弹详情）。
    static func menuBarPad(_ services: AppServices, workspace: Workspace, open: @escaping (Route) -> Void) -> some View {
        MenuBarPad(open: open)
            .environment(workspace)
            .modifier(PaletteProvider())
            .environment(services)
    }
}

/// 主窗口根：按设置切换明暗（连同窗口外框），注入配色。
private struct MainRoot: View {
    let workspace: Workspace
    @Environment(AppServices.self) private var services

    var body: some View {
        content
            .task { await workspace.observeAgentLinks() }
            .task { await workspace.observeFolderGuide() }
            .task { await workspace.observeCue() }
            // 深链（Mac 上只来自点开的 Cue 通知，主窗口已叫到前面）
            .onChange(of: services.pendingDeepLink, initial: true) {
                guard let link = services.consumeDeepLink() else { return }
                switch link {
                case .cue: workspace.show(.cue)
                case .project(let id): workspace.show(.project(id))
                case .card, .capture: break  // 小组件与分享扩展只在 iOS
                }
            }
            .modifier(PaletteProvider())
            .onChange(of: services.settings.theme, initial: true) { _, theme in
                NSApp.appearance = switch theme {
                case .system: nil
                case .light: NSAppearance(named: .aqua)
                case .dark: NSAppearance(named: .darkAqua)
                }
            }
            .debugScene(workspace)
    }

    private var content: some View {
        DebugStage(workspace: workspace) { MainWindow(workspace: workspace) }
    }
}
#endif
