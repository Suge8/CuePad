#if os(macOS)
import SwiftUI

/// 项目范围（`Workspace.projectScope`，进展页看板与会话两段共用一份）在 Mac 上的入口：窗口最顶那一排的工具栏左边（`ScopeSlot`），
/// 进展页右上的"⋯"里也有一份（`ProjectScopeItems`）：全部项目或一个项目，列全部项目。
/// 手机与 iPad 的入口在顶栏中间（`ProjectScope`）。选中的项目进了回收站就当作全部项目（`Workspace.scopedProject`）。
struct ProjectScopeMenu: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let current = workspace.catalog?.project(workspace.scopedProject)
        Menu {
            ProjectScopePicker().pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                if let current { ProjectGlyph(project: current, size: 13) } else { Image(.filter) }
                Text(current?.name ?? "全部项目").lineLimit(1)
            }
            .menuLabel(current.map { "项目范围：\($0.name)" } ?? "项目范围：全部项目")
        }
        .menuStyle(.button).buttonStyle(ControlButtonStyle(kind: .glass)).menuIndicator(.hidden)
        // 横向不定死：给的地方窄于字宽时项目名截断（工具栏里固定宽度的那一格）
        .fixedSize(horizontal: false, vertical: true)
    }
}
/// 进展页"⋯"里的项目范围：一个子菜单，勾着此刻的范围。
struct ProjectScopeItems: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let current = workspace.catalog?.project(workspace.scopedProject)
        Menu {
            ProjectScopePicker().pickerStyle(.inline)
        } label: {
            Label("项目范围：\(current?.name ?? "全部项目")", icon: .filter)
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
                Label { Text(project.name) } icon: { ProjectGlyph(project: project) }.tag(Optional(project.id))
            }
        }
    }
}
#endif
