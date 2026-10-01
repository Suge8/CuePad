#if os(macOS)
import AppKit
import SwiftUI

/// 界面接入点：主窗口与菜单栏面板的根视图都在这里创建。
/// 视图通过环境取得 `AppServices`（`@Environment(AppServices.self)`）与本窗口的 `Workspace`。
@MainActor
enum RootViews {
    static func mainWindow(_ services: AppServices) -> some View {
        MainRoot(workspace: Workspace(services: services)).environment(services)
    }

    /// 设置窗口（⌘, 与菜单"设置…"）的内容。
    static func settings(_ services: AppServices) -> some View {
        VStack(spacing: 0) {
            SettingsView()
            Divider()
            CommandLineToolBar()
            Divider()
            UpdateBar()
        }
        .modifier(PaletteProvider())
        .environment(services)
    }

    static func menuBarPad(_ services: AppServices) -> some View {
        MenuBarPad()
            .environment(Workspace(services: services))
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
            .modifier(PaletteProvider())
            .onChange(of: services.settings.theme, initial: true) { _, theme in
                NSApp.appearance = switch theme {
                case .system: nil
                case .light: NSAppearance(named: .aqua)
                case .dark: NSAppearance(named: .darkAqua)
                }
            }
            #if DEBUG
            .task { await DebugScene.prepare(workspace) }
            .background { if DebugScene.injectsGeometryLoop { GeometryLoopProbe() } }
            #endif
    }

    @ViewBuilder private var content: some View {
        #if DEBUG
        // 截图只截主窗口：菜单栏面板与设置窗口的内容放进主窗口里拍
        if DebugScene.scene == "menubar" {
            DebugMenuBarStage().environment(workspace)
        } else if DebugScene.scene == "settings" {
            SettingsView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            MainWindow(workspace: workspace)
        }
        #else
        MainWindow(workspace: workspace)
        #endif
    }
}
#endif
