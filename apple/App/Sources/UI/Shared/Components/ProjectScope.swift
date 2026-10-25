#if os(iOS)
import SwiftUI

/// 项目范围（`Workspace.projectScope`，进展页两段共用一份），窄屏在顶栏中间：看全部时是"全部项目 ⌄"，选了是项目图标与名字（靛青字、选中底）接一颗 ✕ 清掉。
/// 点字换项目（项目目录里的全部项目，默认项目在内）。只画字与选中底，玻璃由所在的那一块给（进展页与分段、额度环合成一颗）。
/// 选中的项目进了回收站就当作全部项目（`Workspace.scopedProject`）。
struct ProjectScope: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    /// 项目名最宽多少：名字再长也不挤到两侧的圆钮底下。
    private static let nameWidth: CGFloat = 150

    var body: some View {
        @Bindable var workspace = workspace
        let current = workspace.catalog?.project(workspace.scopedProject)
        HStack(spacing: 0) {
            Menu {
                Picker("项目范围", selection: $workspace.projectScope) {
                    Label("全部项目", icon: .all).tag(UUID?.none)
                    ForEach(workspace.catalog?.projects ?? []) { project in
                        Label { Text(project.shownName) } icon: { ProjectGlyph(project: project) }.tag(Optional(project.id))
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    if let current { ProjectGlyph(project: current, size: 13) }
                    (current.map { Text($0.shownName) } ?? Text("全部项目")).fontWeight(current == nil ? nil : .semibold)
                        .lineLimit(1).frame(maxWidth: Self.nameWidth)
                    if current == nil { Image(.expand).font(.caption.weight(.semibold)).accessibilityHidden(true) }
                }
                .menuLabel(current.map { "项目范围：\($0.shownName)" } ?? "项目范围：全部项目")
                .padding(.leading, 14).padding(.trailing, current == nil ? 14 : 4)
                .frame(height: FloatingHeaderLayout.height)
                .contentShape(.capsule)
            }
            .buttonStyle(PressStyle())
            if current != nil {
                Button { workspace.projectScope = nil } label: {
                    Image(.close).font(.caption.weight(.bold))
                        .frame(width: 32, height: FloatingHeaderLayout.height).contentShape(.rect)
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("看全部项目")
            }
        }
        .font(.subheadline)
        .foregroundStyle(current == nil ? palette.ink2 : palette.signature)
        .background { if current != nil { Capsule().fill(palette.selection).padding(3) } }
        .fixedSize()
        .animation(HandOff.quick, value: current?.id)
        .sensoryFeedback(.selection, trigger: current?.id)
    }
}
#endif
