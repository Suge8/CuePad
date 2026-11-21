import CueStore
import SwiftUI

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

struct CueTaskLine: View {
    static let lineHeight: CGFloat = 24

    let task: UUID
    let message: CueMessage
    @Environment(\.palette) private var palette

    var body: some View {
        let place = message.place(task: task), title = message.name(task: task)
        let done = place?.status == .known(.done)
        CueTaskButton(task: task) {
            HStack(spacing: Spacing.glyph) {
                TaskRingView(status: place?.status?.known, done: done, size: 13, steps: place?.progress).relaySpot(task: task)
                Text(title).lineLimit(1)
                Chevron(.forward)
            }
            .font(Typography.meta).foregroundStyle(palette.ink2)
            .frame(minHeight: Self.lineHeight).contentShape(.rect)
        }
        .accessibilityLabel("关于 \(title)")
        .accessibilityValue(done ? "" : place?.progress.map(TaskCopy.progress) ?? "")
        .accessibilityHint("打开任务")
    }
}
