import CueStore
import SwiftUI

extension View {
    /// 值是状态（文案见 `TaskSpeech`），默认动作勾选（与圈同一个动作）。`aside`：标签末尾再念的一句；`more`：调用处多给的动作。
    func taskSpoken(
        _ task: Card, title: String, subtasks: TaskProgress?, next: TaskNext?, aside: String? = nil, check: Binding<TaskCheck>, open: @escaping () -> Void, follow: @escaping () -> Void,
        @ViewBuilder more: () -> some View = { EmptyView() }
    ) -> some View {
        modifier(TaskSpoken(task: task, title: title, subtasks: subtasks, next: next, aside: aside, check: check, open: open, follow: follow, more: more()))
    }
}

private struct TaskSpoken<More: View>: ViewModifier {
    let task: Card
    /// 卡上写的名字（标题为空时是绑着的会话名，`Card.title(session:)`）：念的与看的同一个。
    let title: String
    let subtasks: TaskProgress?
    let next: TaskNext?
    let aside: String?
    @Binding var check: TaskCheck
    let open: () -> Void
    let follow: () -> Void
    let more: More
    @Environment(Workspace.self) private var workspace
    @Environment(\.taskStructure) private var structure


    func body(content: Content) -> some View {
        let done = check.done(task)
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([title, subtasks.map(TaskCopy.progress), next?.speech, aside].compactMap { $0 }.joined(separator: "，"))
            .accessibilityValue(TaskSpeech.value(done ? .done : task.status))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(check.phase == .pending ? String(localized: "撤销完成") : TaskSpeech.toggle(done: done))
            .accessibilityAction { workspace.tap($check, task: task, subtasks: subtasks, busy: next?.busySession) }
            .accessibilityActions {
                Button("打开", action: open)
                more
                switch next {
                case .start: Button("开始", action: follow)
                case .agent: Button("看 Agent 的近况", action: follow)
                case nil: EmptyView()
                }
                RowActionButtons(actions: TaskStructure.spoken.compactMap { $0.rowAction(on: task, in: workspace, structure: structure) })
            }
    }
}
