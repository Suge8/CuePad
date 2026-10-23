import SwiftUI

/// 进展页的两段：看板｜会话两颗图标（选中的靛青浅底），看哪一段只有 `Workspace.progressPane` 一份。三端同一组：
/// iPhone 与 iPad 在顶上那块玻璃里（`ProgressHeader`），Mac 在窗口最顶那一排左上（`PanesSlot`）。
struct ProgressPanes: View {
    /// 一颗的边长。
    let size: CGFloat
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            pane(.board, "看板", icon: .task)
            pane(.sessions, "会话", icon: .session)
        }
    }

    private func pane(_ pane: ProgressPane, _ title: String, icon: Icon) -> some View {
        let on = workspace.progressPane == pane
        return Button {
            withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { workspace.progressPane = pane }
        } label: {
            Image(icon).font(.subheadline.weight(.semibold))
                .foregroundStyle(on ? palette.signature : palette.ink2)
                .frame(width: size, height: size)
                .background(on ? palette.selection : .clear, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(PressStyle())
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
