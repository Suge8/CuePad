import CueStore
import SwiftUI

/// 看板上的一件任务：待办、推进中、已完成三列同一种卡（等你列是同样的卡，`BoardWaitCard`），一样高（`boardCard`），卡上只有标题与一个状态记号，其余收进悬停提示。
/// - 开头是完成圈（`TaskCheckButton`，空心描边；做完是石绿的对勾），看全部项目时标题前一个项目小图形（`BoardProjectGlyph`，Mac 上悬停是项目联动）；
/// - 推进中下沿是那条线、线的右端是要你管的状态词（`BoardPulse`，`BoardCardLayout`），歇着的标题淡一档；已完成标题淡一档、不加粗，卡尾是 Cue 点名的成果图；
/// - 悬停提示：项目、多久（推进中是跑了多久或估还要多久，已完成是几点做完）与交给了哪家 Agent。
/// 上级收成一张（`TaskBoard.Item.leaf`）：状态看此刻干活的叶子。点圈完成（`TaskCheck`）；点卡的其余地方同任务行（`Workspace.enter`）：
/// 开工了的叶子进它的会话，其余打开任务气泡。长按（Mac 右键）是这件任务的菜单（`CardActions`），点卡进的是会话时第一项"打开任务"。
/// Mac 上指针停在卡上卡亮一档（`PressFeedback` 的卡），还没交出去的叶子这时右端浮出"▶ 开始"（不占排版，盖住标题的尾巴）。
struct BoardTaskCard: View {
    let item: TaskBoard.Item
    let column: TaskBoard.Column
    /// 标题前的项目小图形：看全部项目时才有。
    let project: Project?
    /// 下沿那条线可以动（`BoardWave.moves`）。
    var moves = true
    var openShot: (PreviewOpening) -> Void = { _ in }
    @State private var check = TaskCheck()
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardAgents) private var agents
    @Environment(\.palette) private var palette

    private var task: Card { item.task }
    private var advancing: Bool { column == .advancing }

    var body: some View {
        let next = workspace.next(for: task, lead: item.leaf, in: agents, steps: item.steps)
        let pulse = advancing ? workspace.pulse(for: task, lead: item.leaf, in: agents) : BoardPulse()
        framed(next: next) {
            BoardCardLayout(advancing: advancing, pulse: pulse, moves: moves, steps: advancing ? item.steps : nil) {
                ring(next: next)
                if let project { BoardProjectGlyph(project: project) }
                title(resting: pulse.tier == .resting && advancing)
            } trailing: {
                if let shot = item.shot { BoardShot(shot: shot, group: task.id.uuidString, open: openShot) }
            }
            #if os(macOS)
            .overlay(alignment: .trailing) { StartReveal(next: next) }
            #endif
            .boardCard()
        }
        .help(tip)
        .taskSpoken(task, subtasks: item.steps, next: next, check: $check, open: open, follow: { follow(next) }) {
            if let shot = item.shot { Button("看成果") { openShot(BoardShot.opening(shot, group: task.id.uuidString)) } }
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

    /// 标题：点圈停留的那一下最淡、划线（看得清刚勾掉的是哪条）；做完的与推进中歇着的淡一档，做完的不加粗。
    private func title(resting: Bool) -> some View {
        let finished = task.status == .done
        let ink = check.phase != .idle ? palette.ink3 : finished || resting ? palette.ink2 : palette.ink
        return Text(task.title.textGlyphs).fontWeight(finished ? .regular : nil)
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

    private func open() { workspace.openTask(task) }

    private func tap() { workspace.enter(task, leaf: item.steps == nil, in: agents) }

    private func follow(_ next: TaskNext?) {
        if let next { workspace.follow(next) }
    }

    /// 长按（Mac 右键）菜单：点卡进的是会话时第一项"打开任务"（`CardActions.opens`）。
    private var menu: some View {
        let leaf = item.steps == nil
        let opens = workspace.entersSession(task, leaf: leaf, in: agents)
        #if os(macOS)
        return CardActions(card: task, leaf: leaf, opens: opens)
        #else
        return CardActions(card: task, opens: opens)
        #endif
    }

    #if os(macOS)
    private static let ring: CGFloat = 15

    private func framed(next: TaskNext?, @ViewBuilder _ card: () -> some View) -> some View {
        card()
            .modifier(PressFeedback(pressed: false, kind: .card))
            .onTapGesture { tap() }
            .contextMenu { menu }
    }
    #else
    private static let ring: CGFloat = 22

    /// 按住不动出长按菜单；菜单出来后往菜单外一挪就是拖（`BoardColumn` 挂的 `draggable`，系统把两者放在同一次长按里），往菜单里挪是在菜单里选。
    private func framed(next: TaskNext?, @ViewBuilder _ card: () -> some View) -> some View {
        card()
            .onTapGesture { tap() }
            .contentShape(.contextMenuPreview, .rect(cornerRadius: TaskMetrics.cardRadius, style: .continuous))
            .contextMenu { menu }
            .contentShape(.dragPreview, .rect(cornerRadius: TaskMetrics.cardRadius, style: .continuous))
    }
    #endif
}

#if os(macOS)
/// 指针停在卡上时（`buttonHovered`，卡的 `PressFeedback` 给）右端浮出的"▶ 开始"：垫一块纸色、靠字那一侧淡入，盖住标题的尾巴，不挪字。
private struct StartReveal: View {
    let next: TaskNext?
    @Environment(\.buttonHovered) private var hovered
    @Environment(\.palette) private var palette

    var body: some View {
        if hovered, let next, next.starts {
            HStack(spacing: 0) {
                LinearGradient(colors: [palette.paper.opacity(0), palette.paper], startPoint: .leading, endPoint: .trailing).frame(width: RowMetrics.revealFade)
                TaskNextMark(next: next).environment(\.rowHovered, true).background(palette.paper)
            }
            .transition(.opacity)
        }
    }
}
#endif
