#if os(macOS)
import SwiftUI

/// Mac 侧栏最上面一行：头像、名字、此刻在做什么，"等你 N"；点开 Cue 页，开着时是行的选中底（`RowStyle`）。
struct CueSidebarRow: View {
    let select: (Route) -> Void
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let selected = workspace.page == .cue
        Button { select(.cue) } label: {
            CueStatusRow(font: Typography.sidebarRow.weight(selected ? .semibold : .medium))
                .frame(height: Spacing.sidebarProjectRow + 4)
                .contentShape(.rect)
        }
        .buttonStyle(RowStyle(selected: selected))
        .padding(.horizontal, SidebarMetrics.column).padding(.top, 6)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(selected ? "当前页" : "")
        .help("和 \(workspace.cue.name) 说话")
    }
}
#endif
