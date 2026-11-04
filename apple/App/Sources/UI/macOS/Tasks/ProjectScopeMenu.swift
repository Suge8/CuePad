#if os(macOS)
import SwiftUI

/// 项目范围（`Workspace.projectScope`）在 Mac 上只有一处入口：进展页（看板）那一行右端"⋯"里的一个子菜单，勾着此刻的范围（全部项目或一个项目，列全部项目）。
/// 选了项目时"⋯"角上带它的小图形（`PageMenuSlot`）。手机与 iPad 的入口在顶栏中间（`ProjectScope`）。选中的项目进了回收站就当作全部项目（`Workspace.scopedProject`）。
struct ProjectScopeItems: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let current = workspace.catalog?.project(workspace.scopedProject)
        Menu {
            ProjectScopePicker().pickerStyle(.inline)
        } label: {
            Label("项目范围：\(current?.shownName ?? String(localized: "全部项目"))", icon: .filter)
        }
    }
}

/// 全部项目与每个项目，选中的是此刻的范围。
private struct ProjectScopePicker: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        Picker("项目范围", selection: $workspace.projectScope) {
            Label("全部项目", icon: .all).tag(UUID?.none)
            ForEach(workspace.catalog?.projects ?? []) { project in
                Label { Text(project.shownName) } icon: { ProjectGlyph(project: project) }.tag(Optional(project.id))
            }
        }
    }
}
#endif
