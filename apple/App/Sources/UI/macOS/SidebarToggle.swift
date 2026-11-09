#if os(macOS)
import SwiftUI

struct SidebarToggle: View {
    let sizes: WideMetrics
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button("显示或隐藏侧栏", icon: .sidebar) { workspace.toggleRail(sizes) }
            .labelStyle(.iconOnly)
            .buttonStyle(ControlButtonStyle(kind: .icon, size: .compact))
            .railWaitingDot(hidden: !workspace.railShown(sizes))
            .help(Text("显示或隐藏侧栏（⌃⌘S）"))
            .padding(.leading, Chrome.toggle)
            .frame(height: Chrome.band)
    }
}
#endif
