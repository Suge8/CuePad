import CueStore
import SwiftUI

/// 点了立即显示完成，停留 `linger` 再写入、由列表移走：看得清，也来得及反悔，这段时间里再点一下就撤销。要先问的（`CompletionAsk`）答应了才开始停留。
/// 状态只是这一行界面上的过渡，完成与否以 Store 为准：写入落地或别处改了，这一行回到 `idle`。
struct TaskCheck: Equatable {
    enum Phase { case idle, pending, committed }

    var phase = Phase.idle

    static let linger: Duration = .milliseconds(800)

    func done(_ task: Card) -> Bool { task.status == .done || phase != .idle }
}

extension Workspace {
    /// `busy`：在做或在等你的会话（`TaskNext.busySession`），完成前先问它。
    func tap(_ check: Binding<TaskCheck>, task: Card, subtasks: TaskProgress?, busy: SessionState?) {
        if task.status == .done {
            let id = task.id
            return attempt { try await self.reopen(id) }
        }
        switch check.wrappedValue.phase {
        case .idle:
            attempt { try await self.confirmComplete(task.id, subtasks: subtasks, busy: busy) { _ in check.wrappedValue.phase = .pending } }
        case .pending: check.wrappedValue.phase = .idle
        case .committed: break
        }
    }
}

/// Mac 上不用 Button（`ListPress`）：成百上千地出现在任务行里，每颗 Button 一套焦点、按键与读屏的机器，150 条任务点开"还有 N 条"多约 55M 指令。
struct TaskCheckButton: View {
    let task: Card
    var subtasks: TaskProgress?
    var next: TaskNext?
    let size: CGFloat
    let target: CGSize
    @Binding var check: TaskCheck
    /// 点进没激活的窗口的那一下落到哪（Mac，同系统按钮不接首击、落到下面的行上）。
    var rowTap: () -> Void = {}
    @Environment(Workspace.self) private var workspace

    var body: some View {
        trigger
        .accessibilityLabel(check.phase == .pending ? String(localized: "撤销完成") : TaskSpeech.toggle(done: check.done(task)))
        .sensoryFeedback(.success, trigger: check.phase) { $0 == .idle && $1 == .pending }
        .completionAsks(claiming: task.id)
    }

    private var ring: some View {
        TaskRingView(status: task.status, done: check.done(task), size: size, steps: subtasks, running: next?.isRunning ?? false)
            .relaySpot(task: task.id)
            .frame(width: target.width, height: target.height)
            .contentShape(.rect)
    }

    #if os(macOS)
    private var trigger: some View { ring.modifier(ListPress(slop: target.width, action: tap, firstClick: rowTap)) }
    #else
    private var trigger: some View { Button(action: tap) { ring }.buttonStyle(PressStyle(.button)) }
    #endif

    private func tap() { workspace.tap($check, task: task, subtasks: subtasks, busy: next?.busySession) }
}

extension View {
    /// 挂在持有 `check` 的那一行或卡上（`taskSpoken` 已挂），不挂在圈上：看板列里的卡不画圈，读屏照样勾得了。
    /// 停留后写入的是设为完成，不是翻转：等待时别处已做完也不会被翻回去。
    func taskCheck(_ task: Card, check: Binding<TaskCheck>) -> some View {
        modifier(TaskCheckFlow(task: task, check: check))
    }
}

private struct TaskCheckFlow: ViewModifier {
    let task: Card
    @Binding var check: TaskCheck
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        content
        .task(id: check.phase) {
            guard check.phase == .pending else { return }
            try? await Task.sleep(for: TaskCheck.linger)
            guard !Task.isCancelled else { return }
            commit()
        }
        // 停留时就离开了页面（列表收起、换页）：照样写入，不丢这次勾选
        .onDisappear { if check.phase == .pending { commit() } }
        .onChange(of: task.completedAt) { check.phase = .idle }
    }

    private func commit() {
        check.phase = .committed
        let workspace = workspace, check = $check, id = task.id
        Task {
            do {
                try await workspace.complete(id)
            } catch {
                check.wrappedValue.phase = .idle
                workspace.fail(error)
            }
        }
    }
}

/// 任务气泡标题旁的完成圈：自己记着这一下（标题不随它划线）。
struct GoalCheck: View {
    let task: Card
    var subtasks: TaskProgress?
    @State private var check = TaskCheck()

    var body: some View {
        TaskCheckButton(
            task: task, subtasks: subtasks, size: TaskMetrics.titleRing,
            target: CGSize(width: TaskMetrics.chipTarget, height: TaskMetrics.chipTarget), check: $check)
        .taskCheck(task, check: $check)
    }
}
