import CueStore
import SwiftUI

/// 一行只说一遍状态：进行中是静止开口弧，子任务做到哪是圈的分段（所以不写"1/4"），会话在做什么是那个会动的状态标；不写分组标题、不写状态词胶囊。要你管的（`BoardPulse`）才写状态词，它占时间那一格的位置。
/// 旁注的位置：iPhone 与任务气泡里在行尾（窄，行尾就在眼前）；iPad 宽栏与 Mac 的列表紧跟标题（放在行尾时宽窗口里离标题太远，一眼看不到）。
/// 手机长按直接拖动（`TaskOutline`），不挂长按菜单：系统长按菜单弹出后，把预览往下拉是收起菜单、拖不起来，往下面的组或项目段拖就做不到。菜单那几项在左滑里。
struct TaskLine: View {
    let task: Card
    var subtasks: TaskProgress?
    var step = false
    var inBubble = false
    var leads = false
    @State private var check = TaskCheck()
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardAgents) private var agents
    @Environment(\.palette) private var palette
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    #endif

    var body: some View {
        let next = workspace.next(for: task, in: agents, steps: subtasks)
        let done = check.done(task)
        framed(line(next: next, done: done))
            .taskSpoken(task, title: title, subtasks: subtasks, next: next, aside: task.isPinned ? String(localized: "已置顶") : nil, check: $check, open: open) { start(next) }
    }

    private var title: String { task.title(session: agents.items[task.id]?.shownTitle(at: workspace.services.speech)) }

    private func line(next: TaskNext?, done: Bool) -> some View {
        let name = Text(title.textGlyphs)
        let title = (task.isPinned ? Text("\(Text(Image(.pin)).foregroundStyle(palette.ink3)) \(name)") : name).strikethrough(check.phase != .idle, color: palette.ink3).foregroundStyle(titleInk)
            .font(step ? TaskMetrics.stepFont : TaskMetrics.lineFont)
            .lineLimit(titleLines)
        let outcome = done ? nil : self.outcome
        return HStack(alignment: .firstTextBaseline, spacing: TaskMetrics.columnGap) {
            ring(next: next)
            VStack(alignment: .leading, spacing: 0) {
                if stacked {
                    VStack(alignment: .leading, spacing: Spacing.hair) {
                        title
                        HStack(alignment: .firstTextBaseline, spacing: TaskLineLayout.gap) { notes(next: next, done: done, retry: outcome != nil) }.fixedSize()
                    }
                    .padding(.vertical, Self.titlePadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TaskLineLayout(trailing: !inline || inBubble) {
                        title.padding(.vertical, Self.titlePadding)
                        notes(next: next, done: done, retry: outcome != nil)
                    }
                }
                if let outcome {
                    Text(verbatim: outcome.text).font(TaskMetrics.caption).foregroundStyle(outcome.failed ? palette.failure : palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, Spacing.tight)
                        .transition(.opacity)
                }
            }
        }
        .frame(minHeight: TaskMetrics.rowHeight)
        #if os(macOS)
        .hoverReveal(when: !done && next.map { !inlines($0) } ?? false) { if let next { TaskNextMark(next: next).padding(.leading, Spacing.tight) } }
        #endif
        .animation(Motion.fade, value: done)
    }

    private func ring(next: TaskNext?) -> some View {
        let size = step ? TaskMetrics.stepRing : TaskMetrics.ring
        let target = CGSize(width: TaskMetrics.ringColumn, height: Self.ringTarget)
        #if os(macOS)
        return TaskCheckButton(task: task, subtasks: subtasks, next: next, size: size, target: target, check: $check, rowTap: open)
        #else
        return TaskCheckButton(task: task, subtasks: subtasks, next: next, size: size, target: target, check: $check)
        #endif
    }

    private var titleInk: Color {
        if check.phase != .idle { return palette.ink3 }
        return task.status == .done ? palette.ink2 : palette.ink
    }

    @ViewBuilder private func notes(next: TaskNext?, done: Bool, retry: Bool) -> some View {
        let pulse = workspace.pulse(of: agents.items[task.id])
        if !done, !leads, let next, inlines(next) { TaskNextMark(next: next).yields(first: false, ever: !next.speaks).transition(.opacity) }
        if !done, !(next?.speaks ?? false), let meter = pulse.fullContext { ContextFact(meter: meter).font(TaskMetrics.caption).fixedSize() }
        if !done, !pulse.speaks, let pace = TaskPace.of(task, steps: subtasks) {
            Group {
                switch pace {
                case .left(let seconds): Text(TaskPace.left(seconds))
                case .ran(let since): LiveText(style: SessionClock.Elapsed(since: since))
                }
            }
            .font(TaskMetrics.caption).monospacedDigit().foregroundStyle(palette.ink3)
            .yields(first: true)
        }
        if !done, leads, let next, inlines(next) { TaskNextMark(next: next, primary: true, retry: retry).fixedSize().transition(.opacity) }
    }

    private func inlines(_ next: TaskNext) -> Bool {
        guard case .start = next, !leads else { return true }
        #if os(macOS)
        return false
        #else
        return !step
        #endif
    }

    private var outcome: (text: String, failed: Bool)? {
        #if os(macOS)
        guard leads else { return nil }
        return workspace.sessionLaunching(.card(task.id)).outcome(at: workspace.services.speech)
        #else
        return nil
        #endif
    }

    private func open() { workspace.enter(task, session: agents.items[task.id]?.state) }

    private func start(_ next: TaskNext?) {
        if let next { workspace.follow(next) }
    }

    #if os(iOS)
    private var inline: Bool { sizeClass == .regular }
    private var stacked: Bool { typeSize.isAccessibilitySize }
    private var titleLines: Int { typeSize.isAccessibilitySize ? 4 : 2 }
    private static let titlePadding = Spacing.item
    private static let ringTarget: CGFloat = 44

    private func framed(_ content: some View) -> some View {
        content
            .contentShape(.rect)
            .onTapGesture(perform: open)
    }
    #else
    private var inline: Bool { true }
    private var stacked: Bool { false }
    private var titleLines: Int { 1 }
    private static let titlePadding: CGFloat = 0
    private static let ringTarget: CGFloat = TaskMetrics.ring
    @Environment(\.taskIndent) private var indent

    private func framed(_ content: some View) -> some View {
        content
            .padding(.leading, indent)
            .contentShape(.rect)
            .row()
            .benchSpot(task.id)
            .onTapGesture(perform: open)
            .contextMenu {
                let session = agents.items[task.id]?.state
                CardActions(card: task, opens: session != nil, session: session)
            }
            .padding(.vertical, TaskMetrics.rowGap)
    }
    #endif
}
