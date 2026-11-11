import CueStore
import SwiftUI

/// 点了立即显示完成，停留 `linger` 再写入、由列表移走：看得清，也来得及反悔，这段时间里再点一下就撤销。还有没完成的子任务时先问一起完成；它的 Agent 还在做或在等你时先问一句（`agentBusyDialog`：托管的会话一起结束，终端里你开的不结束）。
/// 状态只是这一行界面上的过渡，完成与否以 Store 为准：写入落地或别处改了，这一行回到 `idle`。
struct TaskCheck: Equatable {
    enum Phase { case idle, pending, committed }
    enum Ask: Equatable { case steps, agent(SessionState) }

    var phase = Phase.idle
    var ask: Ask?

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
            if TaskCopy.hasOpen(subtasks) {
                check.wrappedValue.ask = .steps
            } else if let busy {
                check.wrappedValue.ask = .agent(busy)
            } else {
                check.wrappedValue.phase = .pending
            }
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
        .taskCheck(task, subtasks: subtasks, check: $check)
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
    /// 停留后写入的是设为完成，不是翻转：等待时别处已做完也不会被翻回去。
    func taskCheck(_ task: Card?, subtasks: TaskProgress?, check: Binding<TaskCheck>) -> some View {
        modifier(TaskCheckFlow(task: task, subtasks: subtasks, check: check))
    }
}

private struct TaskCheckFlow: ViewModifier {
    let task: Card?
    let subtasks: TaskProgress?
    @Binding var check: TaskCheck
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        content
        .dialog(.verbatim(TaskCopy.openSubtasks(subtasks)), isPresented: asking(.steps), buttons: [DialogButton(title: "全部完成") { check.phase = .pending }])
        .agentBusyDialog(busy, isPresented: Binding(get: { busy != nil }, set: { if !$0, busy != nil { check.ask = nil } })) { check.phase = .pending }
        .task(id: check.phase) {
            guard check.phase == .pending else { return }
            try? await Task.sleep(for: TaskCheck.linger)
            guard !Task.isCancelled else { return }
            commit()
        }
        // 停留时就离开了页面（列表收起、换页）：照样写入，不丢这次勾选
        .onDisappear { if check.phase == .pending { commit() } }
        .onChange(of: task?.completedAt) { check.phase = .idle }
    }

    private var busy: SessionState? { if case .agent(let session) = check.ask { session } else { nil } }

    private func asking(_ ask: TaskCheck.Ask) -> Binding<Bool> {
        Binding(get: { check.ask == ask }, set: { if !$0, check.ask == ask { check.ask = nil } })
    }

    private func commit() {
        guard let id = task?.id else { return }
        check.phase = .committed
        let workspace = workspace, check = $check
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
    }
}
