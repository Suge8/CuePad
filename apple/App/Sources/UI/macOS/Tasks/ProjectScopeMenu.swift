#if os(macOS)
import SwiftUI

/// 选中的项目进了回收站就当作全部项目（`Workspace.scopedProject`）。
struct ProjectScopeItems: View {
    var body: some View { ProjectScopePicker().pickerStyle(.inline) }
}

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
