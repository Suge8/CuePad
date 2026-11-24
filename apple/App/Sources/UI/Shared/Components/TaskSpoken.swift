import CueStore
import SwiftUI

extension View {
    func taskSpoken(
        _ task: Card, title: String, subtasks: TaskProgress?, next: TaskNext?, aside: String? = nil, check: Binding<TaskCheck>, open: @escaping () -> Void, follow: @escaping () -> Void,
        @ViewBuilder more: () -> some View = { EmptyView() }
    ) -> some View {
        modifier(TaskSpoken(task: task, title: title, subtasks: subtasks, next: next, aside: aside, check: check, open: open, follow: follow, more: more()))
    }
}

private struct TaskSpoken<More: View>: ViewModifier {
    let task: Card
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
            .accessibilityAction { workspace.tap($check, task: task) }
            .taskCheck(task, check: $check)
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
