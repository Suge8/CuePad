import CueStore
import SwiftUI

/// 看板上的一件任务：待办、推进中、已完成三列同一种卡（等你列是同样的卡，`BoardWaitCard`），同一列一样高（`boardCard`），卡上只有标题与一个状态记号，其余收进悬停提示。
/// 纸色、标题的墨与字重、圈的深浅随列的轻重（`TaskBoard.Column`，`BoardWeight.swift`）。
/// - 开头是完成圈（`TaskCheckButton`，空心描边；做完是石绿的对勾），看全部项目时标题前一个项目小图形（`BoardProjectGlyph`，Mac 上悬停是项目联动）；
/// - 推进中下沿是那条线（`BoardLine`：过去说过的几句、此刻在跑或停住，右端是此刻状态多久与要你管的状态词），歇着的标题淡一档；已完成卡尾是 Cue 点名的成果图；
/// - 悬停提示：项目、多久（推进中是跑了多久或估还要多久，已完成是几点做完）与交给了哪家 Agent。
/// 上级收成一张（`TaskBoard.Item.leaf`）：状态看此刻干活的叶子。点圈完成（`TaskCheck`）；点卡的其余地方同任务行（`Workspace.enter`）：
/// 开工了的叶子进它的会话，其余打开任务气泡。长按（Mac 右键）是这件任务的菜单（`CardActions`，各处同一份），点卡进的是会话时第一项"打开任务"，
/// 推进中在用的会话还能结束时多一项"结束会话"。置顶的（`Card.isPinned`）标题前一枚图钉。
/// Mac 上指针停在卡上卡亮一档（`PressFeedback` 的卡），还没交出去的叶子这时右端浮出"▶ 开始"（不占排版，盖住标题的尾巴）。
struct BoardTaskCard: View {
    let item: TaskBoard.Item
    let column: TaskBoard.Column
    /// 标题前的项目小图形：看全部项目时才有。
    let project: Project?
    /// 下沿那条线可以动（`BoardLine.moves`）。
    var moves = true
    var openShot: (PreviewOpening) -> Void = { _ in }
    @State private var check = TaskCheck()
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardAgents) private var agents
    @Environment(\.boardArrival) private var arrival
    @Environment(\.palette) private var palette

    private var task: Card { item.task }
    private var advancing: Bool { column == .advancing }

    var body: some View {
        let next = workspace.next(for: task, lead: item.leaf, in: agents, steps: item.steps)
        // 刚从推进中飞出来的也要线（`BoardCardLayout` 起飞时还带着它，随即淡掉）
        let pulse = advancing || arrival?.from == .advancing ? workspace.pulse(for: task, lead: item.leaf, in: agents) : BoardPulse()
        framed(next: next, session: pulse.session) {
            BoardCardLayout(advancing: advancing, pulse: pulse, moves: moves) {
                ring(next: next).opacity(column.leadOpacity)
                if let project { BoardProjectGlyph(project: project) }
                if task.isPinned { BoardPin() }
                title(resting: pulse.tier == .resting && advancing)
            } trailing: {
                if let shot = item.shot { BoardShot(shot: shot, group: task.id.uuidString, open: openShot) }
            }
            #if os(macOS)
            .overlay(alignment: .trailing) { StartReveal(next: next) }
            #endif
            .boardCard(column)
        }
        .help(tip)
        .taskSpoken(task, subtasks: item.steps, next: next, aside: aside(pulse), check: $check, open: open, follow: { follow(next) }) {
            if let shot = item.shot { Button("看成果") { openShot(BoardShot.opening(shot, group: task.id.uuidString)) } }
            if let session = pulse.session {
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

    /// 标题：墨与字重随列（`TaskBoard.Column.titleInk`）；推进中歇着的淡一档；点圈停留的那一下最淡、划线（看得清刚勾掉的是哪条）。
    private func title(resting: Bool) -> some View {
        let ink = check.phase != .idle ? palette.ink3 : resting ? palette.ink2 : column.titleInk(palette)
        return Text(task.title.textGlyphs).fontWeight(column.titleWeight)
            .strikethrough(check.phase != .idle, color: palette.ink3).foregroundStyle(ink)
    }

    /// 悬停提示：项目 · 多久 · 哪家 Agent。
    private var tip: String {
        let agent = (item.leaf.flatMap { workspace.agent(of: $0.id, in: agents) } ?? workspace.agent(of: task.id, in: agents))?.session.agentMark
        let time: String? = switch column {
        case .advancing:
            switch TaskPace.of(task, steps: item.steps) {
            case .left(let seconds): TaskPace.left(seconds)
            case .ran(let since): PiClock.duration(Date.now.timeIntervalSince(since))
            case nil: nil
            }
        case .done: task.completedAt?.formatted(date: .omitted, time: .shortened)
        case .todo, .waiting: nil
        }
        return Dotted(item.project?.shownName, time, agent).visible
    }

    /// 读屏在标题后面多念的：置顶了、在等哪一处做完。
    private func aside(_ pulse: BoardPulse) -> String? {
        Dotted(task.isPinned ? String(localized: "已置顶") : nil, pulse.handoff?.waiting).nonEmpty?.spoken
    }

    private func open() { workspace.openTask(task) }

    private func tap() { workspace.enter(task, leaf: item.steps == nil, in: agents) }

    private func follow(_ next: TaskNext?) {
        if let next { workspace.follow(next) }
    }

    /// 长按（Mac 右键）菜单：点卡进的是会话时第一项"打开任务"（`CardActions.opens`）；歇着、在等 Cue 交出去的那一处时先是去那一处（`HandoffButton`）。
    @ViewBuilder private func menu(session: PiSessionState?) -> some View {
        let leaf = item.steps == nil
        let opens = workspace.entersSession(task, leaf: leaf, in: agents)
        if let session { HandoffButton(session: session) }
        #if os(macOS)
        CardActions(card: task, leaf: leaf, opens: opens, session: session)
        #else
        CardActions(card: task, opens: opens, session: session)
        #endif
    }

    #if os(macOS)
    private static let ring: CGFloat = 15

    private func framed(next: TaskNext?, session: PiSessionState?, @ViewBuilder _ card: () -> some View) -> some View {
        card()
            .modifier(PressFeedback(pressed: false, kind: .card))
            .onTapGesture { tap() }
            .contextMenu { menu(session: session) }
    }
    #else
    private static let ring: CGFloat = 22

    /// 按住不动出长按菜单；菜单出来后往菜单外一挪就是拖（`BoardColumn` 挂的 `draggable`，系统把两者放在同一次长按里），往菜单里挪是在菜单里选。
    private func framed(next: TaskNext?, session: PiSessionState?, @ViewBuilder _ card: () -> some View) -> some View {
        card()
            .onTapGesture { tap() }
            .contentShape(.contextMenuPreview, .rect(cornerRadius: TaskMetrics.cardRadius))
            .contextMenu { menu(session: session) }
    }
    #endif
}

#if os(macOS)
/// 指针停在卡上时（`buttonHovered`，卡的 `PressFeedback` 给）右端浮出的"▶ 开始"：垫一块卡的纸色（`rowSurface`，随列）、靠字那一侧淡入，盖住标题的尾巴，不挪字。
private struct StartReveal: View {
    let next: TaskNext?
    @Environment(\.buttonHovered) private var hovered
    @Environment(\.rowSurface) private var surface
    @Environment(\.palette) private var palette

    var body: some View {
        if hovered, let next, next.starts {
            let surface = surface ?? palette.paper
            HStack(spacing: 0) {
                LinearGradient(colors: [surface.opacity(0), surface], startPoint: .leading, endPoint: .trailing).frame(width: RowMetrics.revealFade)
                TaskNextMark(next: next).environment(\.rowHovered, true).background(surface)
            }
            .transition(.opacity)
        }
    }
}
#endif
