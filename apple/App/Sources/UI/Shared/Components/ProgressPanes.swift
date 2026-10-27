import SwiftUI

/// 进展页的两段：看板｜会话两颗图标，看哪一段只有 `Workspace.progressPane` 一份。三端同一组：
/// iPhone 与 iPad 在顶上那块玻璃里（`ProgressHeader`），Mac 在窗口最顶那一排左上（`PanesSlot`）。
struct ProgressPanes: View {
    /// 一颗的边长。
    let size: CGFloat
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            pane(.board, "看板", icon: .task)
            pane(.sessions, "会话", icon: .session)
        }
    }

    private func pane(_ pane: ProgressPane, _ title: LocalizedStringResource, icon: Icon) -> some View {
        PaneButton(title: title, on: workspace.progressPane == pane) {
            withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { workspace.progressPane = pane }
        } label: {
            Image(icon).font(.subheadline.weight(.semibold)).frame(width: size, height: size)
        }
        .help(Text(title))
        .accessibilityLabel(Text(title))
    }
}

/// 一页里换看哪一段的一颗（进展页的看板｜会话、手机技能与规则页的规则｜技能）：选中的靛青字、浅底，其余次一档的墨。
struct PaneButton<Label: View>: View {
    let title: LocalizedStringResource
    let on: Bool
    let action: () -> Void
    @ViewBuilder var label: Label
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            label
                .foregroundStyle(on ? palette.signature : palette.ink2)
                .background(on ? palette.selection : .clear, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(PressStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
