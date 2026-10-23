#if os(macOS)
import SwiftUI

/// 项目范围（`Workspace.projectScope`，进展页看板与会话两段共用一份）在 Mac 上的入口：在窗口最顶那一排的工具栏左边（`ScopeSlot`）：全部项目或一个项目，列全部项目。
/// 手机与 iPad 的入口在顶栏中间（`ProjectScope`）。选中的项目进了回收站就当作全部项目（`Workspace.scopedProject`）。
struct ProjectScopeMenu: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        let current = workspace.catalog?.project(workspace.scopedProject)
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
#endif
