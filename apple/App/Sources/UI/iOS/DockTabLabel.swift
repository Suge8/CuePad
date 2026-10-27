#if os(iOS)
import SwiftUI

/// 标签栏上一个 tab 的字与图标（`DockRoot`）。
struct DockTabLabel: View {
    let tab: Route
    let selected: Bool
    @Environment(Workspace.self) private var workspace

    var body: some View {
        switch tab {
        case .shelf: Label(SidebarOutline.Entry.projects.title, icon: SidebarOutline.Entry.projects.icon)
        case .progress: Label(SidebarOutline.Entry.progress.title, icon: SidebarOutline.Entry.progress.icon)
        default: Label { Text(verbatim: workspace.cue.name) } icon: { Image(.cue) }
        }
    }
}
#endif
