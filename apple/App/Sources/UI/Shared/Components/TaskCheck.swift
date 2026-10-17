import CueStore
import SwiftUI

/// 点完成圈的这一下（任务行、任务标题、步骤，Mac 与手机同一份）：点了立即显示完成（圈落下对勾、标题划线、手机一下成功触感），
/// 停留 `linger` 再写入、由列表移走——看得清，也来得及反悔：这段时间里再点一下就撤销。还有没完成的步骤时先问一起完成；
/// 它的 Agent 还在做或在等你时先问一句（完成会把它的会话一起结束，`Workspace.toggle`）。已完成的点一下立即回到待办。
/// 状态只是这一行界面上的过渡，完成与否以 Store 为准：写入落地或别处改了，这一行回到 `idle`。
struct TaskCheck: Equatable {
    enum Phase { case idle, pending, committed }
    enum Ask { case steps, agent }

    var phase = Phase.idle
    var ask: Ask?

    /// 完成后停留多久再写入：够看清对勾、来得及反悔。
    static let linger: Duration = .milliseconds(800)

    /// 界面上这一条显示为完成（勾了还没写入也算）。
    func done(_ task: Card) -> Bool { task.status == .done || phase != .idle }
}

extension Workspace {
    /// 点完成圈（圈本身、读屏的默认动作同一条路）。
    func tap(_ check: Binding<TaskCheck>, task: Card, subtasks: TaskProgress?, agentBusy: Bool) {
        if task.status == .done {
            let id = task.id
            return attempt { try await self.toggle(id) }
        }
        switch check.wrappedValue.phase {
        case .idle:
            if TaskCopy.hasOpen(subtasks) {
                check.wrappedValue.ask = .steps
            } else if agentBusy {
                check.wrappedValue.ask = .agent
            } else {
                check.wrappedValue.phase = .pending
            }
        case .pending: check.wrappedValue.phase = .idle
        case .committed: break
        }
    }
}

/// 完成圈的按钮：`TaskRingView` 加点按区（`target` 比圈大，圈在其中居中）与 `TaskCheck` 的确认、停留与写入。
/// Mac 上不用 Button（`ListPress`）：成百上千地出现在任务行里，每颗 Button 一套焦点、按键与读屏的机器，150 条任务点开"还有 N 条"多约 55M 指令。
struct TaskCheckButton: View {
    let task: Card
    var subtasks: TaskProgress?
    var agentBusy = false
    let size: CGFloat
    let target: CGSize
    @Binding var check: TaskCheck
    /// 点进没激活的窗口的那一下落到哪（Mac，同系统按钮不接首击、落到下面的行上）。
    var rowTap: () -> Void = {}
    @Environment(Workspace.self) private var workspace

    var body: some View {
        trigger
        .accessibilityLabel(check.phase == .pending ? "撤销完成" : TaskSpeech.toggle(done: check.done(task)))
        .sensoryFeedback(.success, trigger: check.phase) { $0 == .idle && $1 == .pending }
        .dialog(TaskCopy.openSubtasks(subtasks), isPresented: asking(.steps), buttons: [DialogButton(title: "全部完成") { check.phase = .pending }])
        .dialog(
            "Agent 还在做这件事", isPresented: asking(.agent), message: "完成会把它的会话一起结束。",
            buttons: [DialogButton(title: "完成并结束会话") { check.phase = .pending }])
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

    private var ring: some View {
        TaskRingView(status: task.status, ring: TaskRing(subtasks), done: check.done(task), size: size)
            .relaySpot(task: task.id)
            .frame(width: target.width, height: target.height)
            .contentShape(.rect)
    }

    #if os(macOS)
    private var trigger: some View { ring.modifier(ListPress(slop: target.width, action: tap, firstClick: rowTap)) }
    #else
    private var trigger: some View { Button(action: tap) { ring }.buttonStyle(PressStyle(.button)) }
    #endif

    private func tap() { workspace.tap($check, task: task, subtasks: subtasks, agentBusy: agentBusy) }

    private func asking(_ ask: TaskCheck.Ask) -> Binding<Bool> {
        Binding(get: { check.ask == ask }, set: { if !$0, check.ask == ask { check.ask = nil } })
    }

    /// 写入失败时这一行恢复为未完成，错误照常提示。
    private func commit() {
        check.phase = .committed
        let id = task.id, workspace = workspace, check = $check
        Task {
            do {
                try await workspace.toggle(id)
            } catch {
                check.wrappedValue.phase = .idle
                workspace.fail(error)
            }
        }
    }
}

/// 任务页、任务浮窗标题旁的完成圈：自己记着这一下（标题不随它划线，完成后页面自己换成"完成了"）。
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
