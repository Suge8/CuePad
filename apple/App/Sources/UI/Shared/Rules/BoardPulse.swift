import CueStore

/// 推进中一行此刻在哪一档（任务行与没绑任务的会话行同一条规则）：要你管 → 在跑 → 歇着。排序（`Workspace.byAttention`）、
/// 行尾写什么与标题淡不淡都只按它，会话的状态只经 `PiShown` 判定。
/// - 要你管：行上写出状态词的（`PiShown.speaksOnTask`：出错、被打断、没能送达、待回复、有新回复），与上下文用到九成起的
///   （`UsageLevel.critical`，状态词就是"上下文 94%"）；
/// - 在跑：`PiShown.isRunning`，行尾是会动的状态标加时长；
/// - 歇着：其余（会话停着、等 Cue 回答、还没开会话），行尾只写时长、标题淡一档。
struct BoardPulse: Equatable {
    enum Tier: Int, CaseIterable, Comparable {
        case needsYou, running, resting

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var shown: PiShown?
    var session: PiSessionState?

    /// 任务行：它"下一步"那一格是会话时（`TaskNext.agent`）看那个会话，否则歇着。
    init(_ next: TaskNext?) {
        if case .agent(let shown, let session)? = next { self.init(shown: shown, session: session) } else { self.init() }
    }

    init(shown: PiShown? = nil, session: PiSessionState? = nil) {
        self.shown = shown
        self.session = session
    }

    /// 快满的上下文（九成起，同会话行上的胭脂那一档）。
    var fullContext: PiContextMeter? {
        session?.context.flatMap(PiContextMeter.init).flatMap { $0.level == .critical ? $0 : nil }
    }

    /// 行尾写状态词（状态词或"上下文 94%"），不写时长。
    var speaks: Bool { tier == .needsYou }

    /// 行尾画会话的状态标：在跑的（会动的那条线），与状态词本身带着标的（出错、被打断、没能送达…）；快满的上下文只写"上下文 94%"，歇着的只写时长。
    var showsMark: Bool { tier == .running || shown?.speaksOnTask == true }

    var tier: Tier {
        guard let shown else { return .resting }
        if shown.speaksOnTask || fullContext != nil { return .needsYou }
        return shown.isRunning ? .running : .resting
    }
}

extension Workspace {
    /// 推进中一件此刻的档（`BoardPulse`）：任务看此刻干活的叶子的"下一步"，会话看它自己（同会话行）。
    func pulse(_ work: TaskBoard.Work, agents: AgentLinks) -> BoardPulse {
        switch work.work {
        case .task: BoardPulse(work.item.flatMap { next(for: $0.task, lead: $0.leaf, in: agents, steps: $0.steps) })
        case .session(let session):
            BoardPulse(shown: shown(session, delivery: services.liveSessions.deliveries[session.sessionID]), session: session)
        }
    }

    /// 推进中按档分成几组（要你管 → 在跑 → 歇着，空的档不在内），同一档保持原来的先后。
    func byAttention(_ work: [TaskBoard.Work], agents: AgentLinks) -> [[TaskBoard.Work]] {
        let tiers = Dictionary(grouping: work) { pulse($0, agents: agents).tier }
        return BoardPulse.Tier.allCases.compactMap { tiers[$0] }
    }
}
