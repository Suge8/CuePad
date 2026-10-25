#if os(macOS)
import AppKit
import SwiftUI

/// 主窗口根：按设置切换明暗（连同窗口外框），注入配色。
struct MainRoot: View {
    let workspace: Workspace
    @Environment(AppServices.self) private var services

    var body: some View {
        content
            .modifier(CueRelayStage(workspace: workspace))
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
