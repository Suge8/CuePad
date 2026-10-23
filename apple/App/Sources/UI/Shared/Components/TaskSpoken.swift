import CueStore
import SwiftUI

extension View {
    /// 一条任务给读屏的样子（任务行 `TaskLine`、看板的任务卡 `BoardTaskCard` 同一份）：一行一个元素——"任务内容，子任务 1/4，下一步"，
    /// 值是状态（文案见 `TaskSpeech`），默认动作勾选（与圈同一个动作）；另有打开、开始或看 Agent 的近况，缩进与反缩进（手机上缩进在右滑里）。
    /// `more`：调用处多给的动作（看板已完成卡的"看成果"）。
    func taskSpoken(
        _ task: Card, subtasks: TaskProgress?, next: TaskNext?, check: Binding<TaskCheck>, open: @escaping () -> Void, follow: @escaping () -> Void,
        @ViewBuilder more: () -> some View = { EmptyView() }
    ) -> some View {
        modifier(TaskSpoken(task: task, subtasks: subtasks, next: next, check: check, open: open, follow: follow, more: more()))
    }
}

private struct TaskSpoken<More: View>: ViewModifier {
    let task: Card
    let subtasks: TaskProgress?
    let next: TaskNext?
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
            .accessibilityLabel([task.title, subtasks.map(TaskCopy.progress), next?.speech].compactMap { $0 }.joined(separator: "，"))
            .accessibilityValue(TaskSpeech.value(done ? .done : task.status))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(check.phase == .pending ? "撤销完成" : TaskSpeech.toggle(done: done))
            .accessibilityAction { workspace.tap($check, task: task, subtasks: subtasks, agentBusy: next?.agentBusy ?? false) }
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
