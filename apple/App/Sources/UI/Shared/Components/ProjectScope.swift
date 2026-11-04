#if os(iOS)
import SwiftUI

/// 项目范围（`Workspace.projectScope`），宽屏进展页顶栏中间（窄屏侧栏那一排是一颗圆钮，`NarrowSidebarBar`）：一颗带菜单的胶囊（`chip`），
/// 看全部时是"全部项目 ⌄"，选了是开着的胶囊（项目图标与名字，同全 App 的选中）接一颗清掉的圆钮（`round`）。
/// 点胶囊换项目（项目目录里的全部项目，默认项目在内）。玻璃由所在的那一块给（与额度环合成一颗，`ProgressHeader`），胶囊与圆钮比玻璃矮一档、在里面居中。
/// 选中的项目进了回收站就当作全部项目（`Workspace.scopedProject`）。
struct ProjectScope: View {
    @Environment(Workspace.self) private var workspace

    /// 项目名最宽多少：名字再长也不挤到两侧的圆钮底下。
    private static let nameWidth: CGFloat = 150
    /// 胶囊上项目图标的边长：与胶囊上的字同高。
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
        // 胶囊比玻璃矮一档，左右也让出同样的一截：与玻璃同心
        .padding(.horizontal, Spacing.tight)
        .frame(height: FloatingHeaderLayout.height)
        .fixedSize()
        .animation(Motion.fade, value: current?.id)
        .sensoryFeedback(.selection, trigger: current?.id)
    }
}
#endif
