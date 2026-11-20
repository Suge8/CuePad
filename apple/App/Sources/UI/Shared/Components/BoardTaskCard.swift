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
                if let steps = item.steps { Text(verbatim: "\(steps.done)/\(steps.total)").monospacedDigit().foregroundStyle(palette.ink3) }
                if let finished { Text(verbatim: finished).monospacedDigit().foregroundStyle(palette.ink3) }
                #if os(iOS)
                // Mac 上不放"开始"：把卡拖到推进中就是开始（用上次选的那家与模型），要换的点开任务。触屏拖起来没那么顺手，写着
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
        // 卡不画圈，完成前那一问由整张卡认领
        .completionAsks(claiming: task.id)
    }

    /// 卡没有圈，Cue 交过来的那道光落在标题上。
    private func title(resting: Bool) -> some View {
        let ink = check.phase != .idle ? palette.ink3 : resting ? palette.ink2 : column.titleInk(palette)
        return BoardCardTitle(title.textGlyphs).fontWeight(column.titleWeight)
            .strikethrough(check.phase != .idle, color: palette.ink3).foregroundStyle(ink)
            .relaySpot(task: task.id)
    }

    /// 第二行那一句：会话此刻在做什么（做完的是它最后说的头一句），没有会话的是任务正文的头一行。
    private var note: String? {
        item.agent.flatMap { SessionProgress.said(of: $0.state) } ?? SessionProgress.firstLine(task.rest)
    }

    /// 手机行里的薄条不写：一行里地方给标题，这一行又都是今天做完的。
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
        // 记下多久了只在这里说：写在卡脚上把项目名挤成一个图标，它又不是据以行动的事
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

    private func enter(_ beside: Bool) { workspace.enter(task, session: item.agent?.state, in: beside ? .beside : .main) }

    private func follow(_ next: TaskNext?) {
        if let next { workspace.follow(next) }
    }

    /// 长按菜单与读屏动作同一份。
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
