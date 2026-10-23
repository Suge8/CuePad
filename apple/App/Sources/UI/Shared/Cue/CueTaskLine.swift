import SwiftUI

/// 打开一件任务（Cue 页里提到的那一行、"等你"关联的任务）：从点的地方长出任务气泡（`Workspace.openTask`）。
struct CueTaskButton<Label: View>: View {
    let task: UUID
    @ViewBuilder let label: Label
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button(action: open) { label.contentShape(.rect) }
            .buttonStyle(PressStyle())
    }

    private func open() { workspace.openTask(id: task) }
}

/// 一件活收成一行（对话里 Cue 的话下面、"等你"里关联的那件）：任务圈（有子任务时按子任务分段）、标题，点它打开任务；行尾是这件活交给的会话的状态标
/// （`AgentDot`：正在开会话、在跑、等你……，点它看那个会话；没交出去不画）。Cue 交给会话时接力落在这一行（圈与状态标都挂着锚，`CueRelayStage`），
/// 落下后状态标自己换成会话的真实状态。
struct CueTaskLine: View {
    /// 平时可点的高（对话里、结果卡里）；Cue 页数格子时按它算那一行至少多高（`CuePage.floor`）。
    static let lineHeight: CGFloat = 24

    let ref: CueTaskRef
    /// 可点的高（"等你"卡的末行撑满 44）
    var height = CueTaskLine.lineHeight
    /// 标题至多几行（"等你"卡在辅助功能字号下两行）
    var lines = 1
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 2) {
            CueTaskButton(task: ref.task.id) {
                HStack(spacing: 6) {
                    TaskRingView(status: ref.task.status, done: ref.done, size: 13, steps: ref.progress).relaySpot(task: ref.task.id)
                    Text(ref.task.title).lineLimit(lines).fixedSize(horizontal: false, vertical: lines > 1)
                    Image(.forward).font(.system(size: 9, weight: .semibold))
                }
                .font(Typography.meta).foregroundStyle(palette.ink2)
                .frame(minHeight: height).contentShape(.rect)
            }
            .accessibilityLabel("关于 \(ref.task.title)")
            .accessibilityValue(ref.done ? "" : ref.progress.map(TaskCopy.progress) ?? "")
            .accessibilityHint("打开任务")
            if !ref.done { AgentDot(card: ref.task.id).padding(.vertical, -2) }
        }
    }
}
