import CueStore
import SwiftUI

struct TaskCheck: Equatable {
    enum Phase { case idle, pending, committed }

    var phase = Phase.idle

    static let linger: Duration = .milliseconds(800)

    func done(_ task: Card) -> Bool { task.status == .done || phase != .idle }
}

extension Workspace {
    func tap(_ check: Binding<TaskCheck>, task: Card) {
        if task.status == .done {
            let id = task.id
            return attempt { try await self.reopen(id) }
        }
        switch check.wrappedValue.phase {
        case .idle:
            attempt { try await self.confirmComplete(task.id) { _ in check.wrappedValue.phase = .pending } }
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

    private func tap() { workspace.tap($check, task: task) }
}

extension View {
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
