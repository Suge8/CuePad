import SwiftUI

/// 选中的项目进了回收站就当作全部项目（`Workspace.scopedProject`）。
struct ProjectScopePicker: View {
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

/// 宽屏进展页列头那一排开头的范围钮的图形：筛选，选了项目时角上是那个项目。
struct ProjectScopeLabel: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Image(.filter).overlay(alignment: .topTrailing) {
            if let current = workspace.catalog?.project(workspace.scopedProject) { ProjectGlyph(project: current, size: 10).offset(x: 12, y: -10) }
        }
    }
}

#if os(iOS)
/// 宽屏的进展页没有页头：范围是列头那一排开头的一颗钮（同 Mac 的 `PageMenuSlot`）。
struct ProjectScopeButton: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let current = workspace.catalog?.project(workspace.scopedProject)
        Menu { ProjectScopePicker() } label: {
            ProjectScopeLabel().menuLabel(current.map { "项目范围：\($0.shownName)" } ?? "项目范围：全部项目")
        }
        .buttonStyle(ControlButtonStyle(kind: .circular))
        .sensoryFeedback(.selection, trigger: current?.id)
    }
}
#endif
