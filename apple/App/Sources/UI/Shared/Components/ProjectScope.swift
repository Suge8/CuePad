import SwiftUI

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

struct ProjectScopeLabel: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Image(.filter).overlay(alignment: .topTrailing) {
            if let current = workspace.catalog?.project(workspace.scopedProject) { ProjectGlyph(project: current, size: 10).offset(x: 12, y: -10) }
        }
    }
}
