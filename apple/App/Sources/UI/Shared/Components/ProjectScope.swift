#if os(iOS)
import SwiftUI

/// 选中的项目进了回收站就当作全部项目（`Workspace.scopedProject`）。
struct ProjectScope: View {
    @Environment(Workspace.self) private var workspace

    private static let nameWidth: CGFloat = 150
    private static let glyph: CGFloat = 13

    var body: some View {
        @Bindable var workspace = workspace
        let current = workspace.catalog?.project(workspace.scopedProject)
        HStack(spacing: Spacing.tight) {
            Menu {
                Picker("项目范围", selection: $workspace.projectScope) {
                    Label("全部项目", icon: .all).tag(UUID?.none)
                    ForEach(workspace.catalog?.projects ?? []) { project in
                        Label { Text(project.shownName) } icon: { ProjectGlyph(project: project) }.tag(Optional(project.id))
                    }
                }
            } label: {
                HStack(spacing: Spacing.glyph) {
                    if let current { ProjectGlyph(project: current, size: Self.glyph) }
                    (current.map { Text($0.shownName) } ?? Text("全部项目")).frame(maxWidth: Self.nameWidth)
                }
                .chip(on: current != nil, menu: true, size: .compact)
                .menuLabel(current.map { "项目范围：\($0.shownName)" } ?? "项目范围：全部项目")
            }
            .buttonStyle(PressStyle())
            if current != nil {
                Button("看全部项目", icon: .close) { workspace.projectScope = nil }
                    .labelStyle(.iconOnly)
                    .buttonStyle(ControlButtonStyle(kind: .round, size: .compact))
            }
        }
        .padding(.horizontal, Spacing.tight)
        .frame(height: FloatingHeaderLayout.height)
        .fixedSize()
        .animation(Motion.fade, value: current?.id)
        .sensoryFeedback(.selection, trigger: current?.id)
    }
}
#endif
