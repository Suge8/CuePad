#if os(macOS)
import SwiftUI

/// 项目范围（`Workspace.projectScope`，任务页与会话页共用一份）在 Mac 任务页顶上的入口：全部项目或一个项目，列全部项目。
/// 手机与 iPad 的入口在顶栏中间（`ProjectScope`）。选中的项目进了回收站就当作全部项目。
struct ProjectScopeMenu: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var workspace = workspace
        let current = workspace.catalog?.project(workspace.projectScope)
        Menu {
            Picker("项目范围", selection: $workspace.projectScope) {
                Label("全部项目", icon: .all).tag(UUID?.none)
                ForEach(workspace.catalog?.projects ?? []) { project in
                    Label { Text(project.name) } icon: { ProjectGlyph(project: project) }.tag(Optional(project.id))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                if let current { ProjectGlyph(project: current, size: 13) } else { Image(.all) }
                Text(current?.name ?? "全部项目").lineLimit(1)
            }
            .font(Typography.toolbarLabel).foregroundStyle(palette.ink2)
            .padding(.horizontal, 12).frame(height: Spacing.toolbarControl)
            .glass(in: .capsule, interactive: true)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(current.map { "项目范围：\($0.name)" } ?? "项目范围：全部项目")
    }
}
#endif
