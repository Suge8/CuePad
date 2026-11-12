import CueStore
import SwiftUI

/// 上级收成一张：状态、"下一步"与点卡都只看卡上写的会话（`TaskBoard.Item.agent`，此刻干活那一步的）。
struct BoardTaskCard: View {
    let item: TaskBoard.Item
    let column: TaskBoard.Column
    let project: Project?
    var moves = true
    var openShot: (PreviewOpening) -> Void = { _ in }
    @State private var check = TaskCheck()
    @Environment(Workspace.self) private var workspace
    @Environment(\.boardArrival) private var arrival
    @Environment(\.boardRow) private var row
    @Environment(\.palette) private var palette

    private var task: Card { item.task }
    private var title: String { task.title(session: item.agent?.shownTitle(at: workspace.services.speech)) }
    private var advancing: Bool { column == .advancing }

    var body: some View {
        let now = workspace.pulse(of: item.agent)
        let next = workspace.next(for: item, shown: now.shown)
        let pulse = advancing || arrival?.from == .advancing ? now : BoardPulse()
        framed {
            BoardCardLayout(advancing: advancing, pulse: pulse, moves: moves, project: project) {
                ring(next: next).opacity(column.leadOpacity)
            } title: {
                if task.isPinned { BoardPin() }
                title(resting: pulse.tier == .resting && advancing)
            } facts: {
                if let steps = item.steps { Text(verbatim: "\(steps.done)/\(steps.total)").monospacedDigit().foregroundStyle(palette.ink3) }
                if let finished { Text(verbatim: finished).monospacedDigit().foregroundStyle(palette.ink3) }
                if let next, next.starts { BoardStart(next: next) }
            } trailing: {
                if let shot = item.shot { BoardShot(shot: shot, group: task.id.uuidString, open: openShot) }
            }
            .boardCard(column)
        }
        .help(tip)
        .taskSpoken(task, title: title, subtasks: item.steps, next: next, aside: aside(pulse), check: $check, open: open, follow: { follow(next) }) {
            if let shot = item.shot { Button("看成果") { openShot(BoardShot.opening(shot, group: task.id.uuidString)) } }
            if let session = pulse.session {
                OpenSessionBeside(session: session)
                HandoffButton(session: session)
                if let end = SessionActions.end(session, ending: false, in: workspace) { RowActionButtons(actions: [end]) }
            }
        }
    }

    private func ring(next: TaskNext?) -> some View {
        let target = CGSize(width: TaskMetrics.cardLead, height: TaskMetrics.cardLead)
        #if os(macOS)
        return TaskCheckButton(task: task, subtasks: item.steps, next: next, size: Self.ring, target: target, check: $check) { tap() }
        #else
        return TaskCheckButton(task: task, subtasks: item.steps, next: next, size: Self.ring, target: target, check: $check)
        #endif
    }

    /// 列里的卡没有圈，Cue 交过来的那道光落在标题上；行里的落在圈上（`TaskCheckButton`）。
    @ViewBuilder private func title(resting: Bool) -> some View {
        let ink = check.phase != .idle ? palette.ink3 : resting ? palette.ink2 : column.titleInk(palette)
        let title = BoardCardTitle(title.textGlyphs).fontWeight(column.titleWeight)
            .strikethrough(check.phase != .idle, color: palette.ink3).foregroundStyle(ink)
        if row { title } else { title.relaySpot(task: task.id) }
    }

    /// 今天做完的写时刻，更早的写日子。
    private var finished: String? {
        guard column == .done, let at = task.completedAt else { return nil }
        return Calendar.current.isDateInToday(at) ? at.formatted(date: .omitted, time: .shortened) : at.formatted(.dateTime.month().day())
    }

    private var tip: String {
        let agent = item.agent?.state.agentMark
        let time: String? = switch column {
        case .advancing:
            switch TaskPace.of(task, steps: item.steps) {
            case .left(let seconds): TaskPace.left(seconds)
            case .ran(let since): SessionClock.duration(Date.now.timeIntervalSince(since))
            case nil: nil
            }
        case .done: task.completedAt?.formatted(date: .omitted, time: .shortened)
        case .todo, .waiting: nil
        }
        return Dotted(item.project?.shownName, time, agent).visible
    }

    private func aside(_ pulse: BoardPulse) -> String? {
        Dotted(task.isPinned ? String(localized: "已置顶") : nil, pulse.handoff?.waiting).nonEmpty?.spoken
    }

    private func open() { workspace.openTask(task) }

    private func tap() {
        #if os(macOS)
        enter(NSApp.currentEvent?.modifierFlags.contains(.command) == true)
        #else
        enter(false)
        #endif
    }

    private func enter(_ beside: Bool) { workspace.enter(task, session: item.agent?.state, in: beside ? .beside : .main) }

    private func follow(_ next: TaskNext?) {
        if let next { workspace.follow(next) }
    }

    @ViewBuilder private var menu: some View {
        let session = item.agent?.state
        if let session { OpenSessionBeside(session: session); HandoffButton(session: session) }
        CardActions(card: task, leaf: item.steps == nil, opens: session != nil, session: session)
    }

    #if os(macOS)
    private static let ring: CGFloat = 15

    private func framed(@ViewBuilder _ card: () -> some View) -> some View {
        card()
            .modifier(PressFeedback(pressed: false, kind: .card))
            .onTapGesture { tap() }
            .contextMenu { menu }
    }
    #else
    private static let ring: CGFloat = 22

    /// 按住不动出长按菜单；菜单出来后往菜单外一挪就是拖（`BoardColumn` 挂的 `draggable`，系统把两者放在同一次长按里），往菜单里挪是在菜单里选。
    private func framed(@ViewBuilder _ card: () -> some View) -> some View {
        Group {
            if workspace.layout == .wide { card().gesture(SessionTap(action: enter)) }
            else { card().onTapGesture { tap() } }
        }
            .contentShape(.contextMenuPreview, .rect(cornerRadius: TaskMetrics.cardRadius))
            .contextMenu { menu }
    }
    #endif
}

/// 卡脚右端的"开始"：Mac 上指针停在卡上才露出（一列十几张，一直写着是一墙"开始"），触屏没有悬停、一直写着。
private struct BoardStart: View {
    let next: TaskNext
    #if os(macOS)
    @Environment(\.buttonHovered) private var hovered
    #endif

    var body: some View {
        #if os(macOS)
        if hovered { TaskNextMark(next: next).environment(\.rowHovered, true).transition(.opacity) }
        #else
        TaskNextMark(next: next)
        #endif
    }
}
