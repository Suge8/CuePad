#if os(macOS)
import SwiftUI

/// Mac 侧栏最上面一行：头像、名字、此刻在做什么，"等你 N"；点开 Cue 页，开着时垫选中底。
struct CueSidebarRow: View {
    let select: (Route) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let selected = workspace.page == .cue
        Button { select(.cue) } label: {
            CueStatusRow(font: Typography.sidebarRow.weight(selected ? .semibold : .medium))
                .padding(.horizontal, 6)
                .frame(height: Spacing.sidebarProjectRow + 4)
                .background(selected ? palette.selection : .clear, in: .rect(cornerRadius: 8))
                .contentShape(.rect)
        }
        .buttonStyle(PressStyle())
        .padding(.horizontal, 10).padding(.top, 6)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(selected ? "当前页" : "")
        .help("和 \(workspace.cue.name) 说话")
    }
}
#endif
