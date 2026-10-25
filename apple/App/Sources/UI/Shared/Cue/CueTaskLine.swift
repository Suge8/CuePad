import CueStore
import SwiftUI

/// 打开一件任务（Cue 页里提到的那一行、拍板卡眉题上的任务）：从点的地方长出任务气泡（`Workspace.openTask`）。
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

/// 一件活收成一行（对话里 Cue 的话下面、结果卡里）：写下那一刻的样子（`CuePlace`：任务圈，有子任务时按子任务分段；标题），点它打开任务。
/// 是记录，不读这件活此刻的状态与它交给的会话：之后改名、做完、删掉都不变（删了、归档了点它提示去向，`Workspace.openTask`）。
/// Cue 交给会话时接力落在圈上（`CueRelayStage`）。
struct CueTaskLine: View {
    /// 可点的高；Cue 页数格子时按它算那一行至少多高（`CuePage.floor`）。
    static let lineHeight: CGFloat = 24

    let task: UUID
    /// 写下这一句的那条对话（这件活当时的样子记在它上面）
    let message: CueMessage
    @Environment(\.palette) private var palette

    var body: some View {
        let place = message.place(task: task), title = message.name(task: task)
        let done = place?.status == .known(.done)
        CueTaskButton(task: task) {
            HStack(spacing: 6) {
                TaskRingView(status: place?.status?.known, done: done, size: 13, steps: place?.progress).relaySpot(task: task)
                Text(title).lineLimit(1)
                Image(.forward).font(.system(size: 9, weight: .semibold))
            }
            .font(Typography.meta).foregroundStyle(palette.ink2)
            .frame(minHeight: Self.lineHeight).contentShape(.rect)
        }
        .accessibilityLabel("关于 \(title)")
        .accessibilityValue(done ? "" : place?.progress.map(TaskCopy.progress) ?? "")
        .accessibilityHint("打开任务")
    }
}
