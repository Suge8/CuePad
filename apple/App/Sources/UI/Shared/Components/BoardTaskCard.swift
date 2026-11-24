import CueStore
import SwiftUI

struct BoardTaskCard: View {
    let item: TaskBoard.Item
    let column: TaskBoard.Column
    let project: Project?
    var moves = true
    var openShot: (PreviewOpening) -> Void = { _ in }
    @State private var check = TaskCheck()
    @Environment(Workspace.self) private var workspace
    @Environment(\.boardRow) private var row
    @Environment(\.palette) private var palette

    private var task: Card { item.task }
    private var title: String { task.title(session: item.agent?.shownTitle(at: workspace.services.speech)) }
    private var advancing: Bool { column == .advancing }

    var body: some View {
        let now = workspace.pulse(of: item.agent)
        let next = workspace.next(for: item, shown: now.shown)
        let pulse = advancing ? now : BoardPulse()
        let hero = column == .done && !row ? item.shot : nil
        framed {
            VStack(alignment: .leading, spacing: 0) {
            if let hero { BoardShot(shot: hero, group: task.id.uuidString, hero: true, open: openShot).padding(.top, TaskMetrics.cardPadding) }
            BoardCardLayout(advancing: advancing, pulse: pulse, moves: moves, project: project, note: note, session: item.agent?.state, compact: column.light) {
                if task.isPinned { BoardPin() }
                title(resting: pulse.tier == .resting && advancing)
            } facts: {
                if let steps = item.steps { Text(verbatim: "\(steps.done)/\(steps.total)").foregroundStyle(palette.ink3) }
                if let finished { Text(verbatim: finished).foregroundStyle(palette.ink3) }
                #if os(iOS)
                if column == .todo, let start = next.flatMap({ $0.starts ? $0 : nil }) { TaskNextMark(next: start) }
                #endif
            } trailing: {
                if hero == nil, let shot = item.shot { BoardShot(shot: shot, group: task.id.uuidString, open: openShot) }
            }
            }
            .boardCard(column, running: moves && pulse.tier == .running)
            .boardRescue(advancing ? item.agent?.state : nil)
        }
        .help(tip)
        .taskSpoken(task, title: title, subtasks: item.steps, next: next, aside: aside(pulse), check: $check, open: open, follow: { follow(next) }) { menu }
        .completionAsks(claiming: task.id)
    }

    private func title(resting: Bool) -> some View {
        let ink = check.phase != .idle ? palette.ink3 : resting ? palette.ink2 : column.titleInk(palette)
        return BoardCardTitle(title.textGlyphs).emphasis(column.titleWeight)
            .strikethrough(check.phase != .idle, color: palette.ink3).foregroundStyle(ink)
            .relaySpot(task: task.id)
    }

    private var note: String? {
        item.agent.flatMap { SessionProgress.said(of: $0.state) } ?? SessionProgress.firstLine(task.rest)
    }

    private var finished: String? { column == .done && !row ? task.completedAt.map { DateLabel.short($0) } : nil }

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
        case .todo: DateLabel.short(task.todoAt ?? task.createdAt)
        case .waiting: nil
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

    private func enter(_ beside: Bool) { workspace.enter(task, session: item.agent?.state, in: beside ? .aside : .main) }

    private func follow(_ next: TaskNext?) {
        if let next { workspace.follow(next) }
    }

    @ViewBuilder private var menu: some View {
        let session = item.agent?.state
        if let shot = item.shot {
            Section { Button("看成果", icon: .looked) { openShot(BoardShot.opening(shot, group: task.id.uuidString)) } }.menuIcons()
        }
        CardActions(card: task, opens: session != nil, session: session)
    }

    #if os(macOS)
    private func framed(@ViewBuilder _ card: () -> some View) -> some View {
        card()
            .modifier(PressFeedback(pressed: false, kind: .card))
            .onTapGesture { tap() }
            .contextMenu { menu }
    }
    #else
    /// 按住 0.2 秒卡就拎起来、能拖（`BoardLift`）；接着按住不动到半秒出长按菜单，菜单出来后往菜单外一挪是系统的拖放（`BoardColumn` 挂的 `draggable`，
    /// 系统把两者放在同一次长按里），往菜单里挪是在菜单里选。
    private func framed(@ViewBuilder _ card: () -> some View) -> some View {
        Group {
            if workspace.layout == .wide { card().gesture(SessionTap(action: enter)) }
            else { card().onTapGesture { tap() } }
        }
            .contentShape(.contextMenuPreview, .rect(cornerRadius: Radius.card))
            .contextMenu { menu }
    }
    #endif
}
