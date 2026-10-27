import CueStore
import SwiftUI

/// 推进中一张卡此刻的样子（任务卡与没绑任务的会话卡同一条规则），只按这一份分：排在哪一档（`Workspace.byAttention`）、
/// 卡下沿那条线（`trace`，`BoardLine` 画）、线右端写哪个状态词（`word`）、线与词什么颜色（`tint`）、标题淡不淡。会话的状态只经 `PiShown` 判定。
/// - 要你管：写出状态词的（`PiShown.speaksOnTask`：出错、被打断、没能送达、待回复、有新回复），与上下文用到九成起的
///   （`UsageLevel.critical`，状态词就是"上下文 94%"）；线停住，末端一颗点与状态词同色；
/// - 在跑：`PiShown.isRunning`，线在动、靛青；
/// - 歇着：其余（会话停着、等 Cue 回答、还没开会话），一条静止的淡线、不带点，标题淡一档；这次停下 Cue 已交给别处时线换成在等哪一处做完（`handoff`）。
struct BoardPulse: Equatable {
    enum Tier: Int, CaseIterable, Comparable {
        case needsYou, running, resting

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// 卡下沿那条线"现在"那一截：装饰，不对应真实事件，只认得出"在干哪类活""停住了"。
    enum Trace: Equatable {
        /// 在跑：按在干的活挑一种预先画好的线；派了子代理的换成在跑的子代理各一条轨。
        case running(Gait, subagents: Int)
        /// 停住：末端一颗点（颜色同状态词，`tint`）；被打断（`broken`）是断线——停在半路，说一句就接着做。
        case stopped(broken: Bool)
        /// 歇着：一条淡线、不带点——横线就是"没在动"。等高的卡下沿不空着，不像没画完。
        case resting
    }

    /// 在干哪类活：在想（含输出、话在路上）是慢而平的起伏，用工具是平线上几个圆鼓包，压缩上下文是细密的波纹。
    nonisolated enum Gait: Equatable, Sendable { case think, tool, compact }

    /// 线右端要你管的那个词。
    enum Word: Equatable {
        case state(PiShown)
        case context(PiContextMeter)
    }

    var shown: PiShown?
    var session: PiSessionState?
    /// 歇着、这次停下 Cue 已交给别处时交给了哪（`PiProgress.handoff`）
    var handoff: CueHandoff?

    init(shown: PiShown? = nil, session: PiSessionState? = nil, handoff: CueHandoff? = nil) {
        self.shown = shown
        self.session = session
        self.handoff = shown.flatMap { PiProgress.handoff(handoff, shown: $0) }
    }

    /// 快满的上下文（九成起，同会话行上的胭脂那一档）。
    var fullContext: PiContextMeter? {
        session?.context.flatMap(PiContextMeter.init).flatMap { $0.level == .critical ? $0 : nil }
    }

    /// 要你管的状态词：会话的状态词在先，其次快满的上下文。
    var word: Word? {
        if let shown, shown.speaksOnTask { return .state(shown) }
        return fullContext.map(Word.context)
    }

    /// 线右端写状态词。
    var speaks: Bool { word != nil }

    var tier: Tier {
        guard let shown else { return .resting }
        if speaks { return .needsYou }
        return shown.isRunning ? .running : .resting
    }

    var trace: Trace {
        switch tier {
        case .resting: return .resting
        case .needsYou: return .stopped(broken: shown?.status == .interrupted)
        case .running:
            let subagents = session?.subagents.count { $0.phase == .known(.running) } ?? 0
            let gait: Gait = switch shown?.status {
            case .working(.tool): .tool
            case .working(.compacting): .compact
            default: .think
            }
            return .running(gait, subagents: subagents)
        }
    }

    /// 线"现在"那一截与状态词的颜色：状态词同 `PiShown.labelTint`，快满的上下文胭脂，在跑靛青，歇着淡墨。
    func tint(_ palette: Palette) -> Color {
        switch word {
        case .state(let shown): shown.labelTint(palette)
        case .context: palette.failure
        case nil: tier == .running ? palette.signature : palette.ink3
        }
    }

    /// 线过去那段最后一颗点（最近说的那句）：在跑时现在那一截从它长出，同 `tint`；否则同更早的点，淡墨。
    func lastSaidTint(_ palette: Palette) -> Color {
        tier == .running ? tint(palette) : palette.ink3
    }
}

extension Workspace {
    /// 任务卡此刻的样子：看此刻干活的叶子交给的会话，没有再看任务自己的（同"下一步"的先后）；会话歇着、"下一步"不写它时也照样看，
    /// 快满的上下文不因此漏掉。都没交给会话是歇着。
    func pulse(for task: Card, lead: Card?, in agents: AgentLinks) -> BoardPulse {
        guard let id = watched(task, lead: lead, in: agents), let agent = agent(of: id, in: agents) else { return BoardPulse() }
        return BoardPulse(shown: agent.shown, session: agent.session, handoff: agents.items[id]?.handoff)
    }

    /// 任务卡看谁交给的会话：此刻干活的叶子，没有再看任务自己。
    private func watched(_ task: Card, lead: Card?, in agents: AgentLinks) -> UUID? {
        [lead?.id, task.id].compactMap(\.self).first { agents.items[$0] != nil }
    }

    /// 推进中一件看的是哪个会话（同 `pulse`），不推它此刻的样子：列只要知道是谁时用（读说过的话，`SaidReading`）。
    func sessionID(_ work: TaskBoard.Work, agents: AgentLinks) -> String? {
        switch work.work {
        case .task: work.item.flatMap { item in watched(item.task, lead: item.leaf, in: agents).flatMap { agents.items[$0]?.state.sessionID } }
        case .session(let session): session.sessionID
        }
    }

    /// 推进中一件此刻的样子（`BoardPulse`）：任务同任务卡，会话看它自己（同会话卡）。
    func pulse(_ work: TaskBoard.Work, agents: AgentLinks) -> BoardPulse {
        switch work.work {
        case .task: work.item.map { pulse(for: $0.task, lead: $0.leaf, in: agents) } ?? BoardPulse()
        case .session(let session): pulse(of: session)
        }
    }

    /// 没绑任务的会话卡此刻的样子。
    func pulse(of session: PiSessionState) -> BoardPulse {
        let id = session.sessionID
        return BoardPulse(shown: shown(session, delivery: services.liveSessions.deliveries[id]), session: session, handoff: services.liveSessions.handoffs[id])
    }

    /// 推进中按档分成几组（要你管 → 在跑 → 歇着，空的档不在内），同一档保持原来的先后。
    func byAttention(_ work: [TaskBoard.Work], agents: AgentLinks) -> [(tier: BoardPulse.Tier, work: [TaskBoard.Work])] {
        let tiers = Dictionary(grouping: work) { pulse($0, agents: agents).tier }
        return BoardPulse.Tier.allCases.compactMap { tier in tiers[tier].map { (tier, $0) } }
    }
}
