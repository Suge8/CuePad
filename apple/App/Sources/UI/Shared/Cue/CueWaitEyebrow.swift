import CueStore
import SwiftUI

struct CueWaitEyebrow: View {
    let wait: CueWait
    let index: Int
    let count: Int
    let counter: AccessibilityFocusState<String?>.Binding
    let step: (Int) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    static let height: CGFloat = 20

    var body: some View {
        HStack(spacing: 0) {
            project
            name.layoutPriority(-1)
            Spacer(minLength: Spacing.group)
            LiveText(style: SessionClock.Waited(since: wait.since)).monospacedDigit().fixedSize()
            if count > 1 { position.padding(.leading, Spacing.item) }
        }
        .font(Typography.caption)
        .foregroundStyle(palette.ink3)
        .frame(height: Self.height)
    }

    @ViewBuilder private var project: some View {
        if let project = workspace.catalog?.project(wait.project) {
            HStack(spacing: Spacing.hair) {
                ProjectGlyph(project: project, size: 11)
                Text(project.shownName).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .fixedSize()
            .padding(.trailing, Spacing.item)
        }
    }

    @ViewBuilder private var name: some View {
        let title = wait.title ?? workspace.cue.name
        switch wait.wait {
        case .message(let message, _):
            if let task = wait.task?.id ?? message.taskID {
                CueTaskButton(task: task) { label(title, linked: true).relaySpot(task: task) }
                    .accessibilityHint("打开任务")
            } else {
                label(title, linked: false)
            }
        case .session(let session, _):
            Button { workspace.openSession(session.id, sessionID: session.sessionID) } label: { label(title, linked: true) }
                .buttonStyle(PressStyle())
                .accessibilityHint("打开会话")
        }
    }

    private func label(_ title: String, linked: Bool) -> some View {
        HStack(spacing: Spacing.hair) {
            Text(title).lineLimit(1)
            if linked { Chevron(.forward) }
        }
        .foregroundStyle(palette.ink2)
        // 小字本身矮：点得到的范围往上下扩，不撑高这一行
        .contentShape(.rect.inset(by: -Self.reach))
    }

    private var position: some View {
        HStack(spacing: 0) {
            #if os(macOS)
            arrow(.back, enabled: index > 0, label: "上一件") { step(-1) }
            #endif
            // 读屏在这一格上下扫换一件（同滑卡、小箭头）：动作挂在已有的元素上，挂在卡上的话整张卡多出一个没有标签的元素（#67）
            Text("\(index + 1)/\(count)").monospacedDigit()
                .accessibilityLabel("第 \(index + 1) 件，共 \(count) 件")
                .accessibilityFocused(counter, equals: wait.id)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: step(1)
                    case .decrement: step(-1)
                    @unknown default: break
                    }
                }
            #if os(macOS)
            arrow(.forward, enabled: index < count - 1, label: "下一件") { step(1) }
            #endif
        }
        .fixedSize()
    }

    #if os(macOS)
    private func arrow(_ direction: Chevron.Direction, enabled: Bool, label: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Chevron(direction).frame(width: Self.height, height: Self.height).contentShape(.rect)
        }
        .buttonStyle(PressStyle(.inline))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
    #endif

    private static let reach: CGFloat = 10
}
