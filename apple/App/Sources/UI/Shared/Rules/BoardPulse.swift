import CueStore

/// 推进中一张卡此刻的样子（任务卡与没绑任务的会话卡同一条规则），只按这一份分：排在哪一档（`Workspace.byAttention`）、
/// 卡下沿那条线（`trace`，`BoardWave` 画）、右上写不写状态词、标题淡不淡。会话的状态只经 `PiShown` 判定。
/// - 要你管：写出状态词的（`PiShown.speaksOnTask`：出错、被打断、没能送达、待回复、有新回复），与上下文用到九成起的
///   （`UsageLevel.critical`，状态词就是"上下文 94%"）；线停住；
/// - 在跑：`PiShown.isRunning`，线在动；
/// - 歇着：其余（会话停着、等 Cue 回答、还没开会话），没有线、标题淡一档。
struct BoardPulse: Equatable {
    enum Tier: Int, CaseIterable, Comparable {
        case needsYou, running, resting

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// 卡下沿那条线：装饰，不对应真实事件，只认得出"在干哪类活""停住了"。
    enum Trace: Equatable {
        /// 在跑：按在干的活挑一种预先画好的线；派了子代理的另有在跑的子代理各一条细轨。
        case running(Gait, subagents: Int)
        /// 停住：出错类（出错、没能送达、上下文快满）是胭脂平线，被打断是灰色断线，其余（待回复、有新回复）是状态词那种颜色的平线。
        case stopped(Stop)
        case none
    }

    /// 在干哪类活：在想（含输出、话在路上）是慢而平的起伏，用工具是平线上几个尖峰，压缩上下文是细密的波纹。
    nonisolated enum Gait: Equatable, Sendable { case think, tool, compact }

    nonisolated enum Stop: Equatable, Sendable { case failure, interrupted, quiet }

    var shown: PiShown?
    var session: PiSessionState?

    init(shown: PiShown? = nil, session: PiSessionState? = nil) {
        self.shown = shown
        self.session = session
    }

    /// 快满的上下文（九成起，同会话行上的胭脂那一档）。
    var fullContext: PiContextMeter? {
        session?.context.flatMap(PiContextMeter.init).flatMap { $0.level == .critical ? $0 : nil }
    }

    /// 右上写状态词（状态词或"上下文 94%"）。
    var speaks: Bool { tier == .needsYou }

    var tier: Tier {
        guard let shown else { return .resting }
        if shown.speaksOnTask || fullContext != nil { return .needsYou }
        return shown.isRunning ? .running : .resting
    }

    var trace: Trace {
        guard let shown else { return .none }
        switch tier {
        case .resting: return .none
        case .needsYou:
            if shown.status == .failed || shown.undelivered != nil || fullContext != nil { return .stopped(.failure) }
            return .stopped(shown.status == .interrupted ? .interrupted : .quiet)
        case .running:
            let subagents = session?.subagents.count { $0.phase == .known(.running) } ?? 0
            let gait: Gait = switch shown.status {
            case .working(.tool): .tool
            case .working(.compacting): .compact
            default: .think
            }
            return .running(gait, subagents: subagents)
        }
    }
}

extension BoardPulse.Trace {
    /// 在跑而且有子代理细轨（线高一些，`WaveStrip.height`）。
    var hasTracks: Bool { if case .running(_, let subagents) = self { subagents > 0 } else { false } }
}

extension Workspace {
    /// 任务卡此刻的样子：看此刻干活的叶子交给的会话，没有再看任务自己的（同"下一步"的先后）；会话歇着、"下一步"不写它时也照样看，
    /// 快满的上下文不因此漏掉。都没交给会话是歇着。
    func pulse(for task: Card, lead: Card?, in agents: AgentLinks) -> BoardPulse {
        guard let agent = lead.flatMap({ agent(of: $0.id, in: agents) }) ?? agent(of: task.id, in: agents) else { return BoardPulse() }
        return BoardPulse(shown: agent.shown, session: agent.session)
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
        BoardPulse(shown: shown(session, delivery: services.liveSessions.deliveries[session.sessionID]), session: session)
    }

    /// 推进中按档分成几组（要你管 → 在跑 → 歇着，空的档不在内），同一档保持原来的先后。
    func byAttention(_ work: [TaskBoard.Work], agents: AgentLinks) -> [(tier: BoardPulse.Tier, work: [TaskBoard.Work])] {
        let tiers = Dictionary(grouping: work) { pulse($0, agents: agents).tier }
        return BoardPulse.Tier.allCases.compactMap { tier in tiers[tier].map { (tier, $0) } }
    }
}
