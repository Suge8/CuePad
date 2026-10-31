#if os(macOS)
import SwiftUI

struct WideRailTools: View {
    let wide: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 8) {
            if wide { SidebarQuota() }
            Menu {
                Button("新建项目", icon: .newProject) { workspace.projectForm = .init() }
                Button("归档", icon: .archive) { workspace.show(.archive) }
                Button("回收站", icon: .trash) { workspace.show(.trash) }
                Button("技能与规则", icon: .instruction) { workspace.show(.library) }
                Button("设置…", icon: .settings) { SettingsPane.open() }
            } label: { Image(.more) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .accessibilityLabel("更多")
        }
        .padding(12)
        .background(palette.sidebar)
    }
}
#endif
