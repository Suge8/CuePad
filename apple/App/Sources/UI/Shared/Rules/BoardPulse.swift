import CueStore
import SwiftUI

/// 推进中一张卡此刻的样子（任务卡与没绑任务的会话卡同一条规则）只按这一份分；会话的状态只经 `SessionShown` 判定。
struct BoardPulse: Equatable {
    enum Tier: Int, CaseIterable, Comparable {
        case needsYou, running, resting

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum Word: Equatable {
        case state(SessionShown)
        case context(ContextMeter)
    }

    var shown: SessionShown?
    var session: SessionState?
    var handoff: CueHandoff?

    init(shown: SessionShown? = nil, session: SessionState? = nil, handoff: CueHandoff? = nil) {
        self.shown = shown
        self.session = session
        self.handoff = handoff
    }

    var fullContext: ContextMeter? {
        session?.context.flatMap(ContextMeter.init).flatMap { $0.level == .critical ? $0 : nil }
    }

    var word: Word? {
        if let shown, shown.speaksOnTask { return .state(shown) }
        return fullContext.map(Word.context)
    }

    var speaks: Bool { word != nil }

    var tier: Tier {
        guard let shown else { return .resting }
        if speaks { return .needsYou }
        return shown.isRunning ? .running : .resting
    }

    /// 推进中的先后按它，不按 `tier`：要你管的在前，睡了的（没有会话、已休眠）在后，其余同一档——在跑与歇着每一轮都来回换，
    /// 按它们排卡就跟着来回换位置；休眠与唤醒才是难得的一次。
    var steadyTier: Tier {
        if speaks { return .needsYou }
        guard let shown else { return .resting }
        if case .ended = shown.status { return .resting }
        return .running
    }

    func tint(_ palette: Palette) -> Color {
        switch word {
        case .state(let shown): shown.labelTint(palette)
        case .context: palette.failure
        case nil: tier == .running ? palette.signature : palette.ink3
        }
    }
}

extension Workspace {
    /// Mac 上本机在线的会话换上桥上的实时状态。任务行（项目页）给的是窗口那一份里交给这条的会话，规则相同。
    func pulse(of agent: SessionListItem?) -> BoardPulse {
        guard let agent else { return BoardPulse() }
        #if os(macOS)
        let live = withLiveState(agent)
        #else
        let live = agent
        #endif
        let shown = shown(live)
        return BoardPulse(shown: shown, session: live.state, handoff: handoff(of: live.state, shown: shown))
    }

    /// 推进中的一组：`work` 里每张带着它此刻在不在跑（卡边那道光只给在跑的）。
    typealias Attention = (pinned: Bool, tier: BoardPulse.Tier, work: [(work: TaskBoard.Work, running: Bool)])

    /// 置顶的任务在最前：置顶是你亲手定的先后，排在档之前。
    /// 卡只在换列时动，同一列里的位置不跟着会话每一轮的状态变（`BoardPulse.steadyTier`）。没绑任务的会话按开的先后排，
    /// 不按最近一次换状态的时刻（读库的那一份是后者，同样一换状态就换位置）。
    func byAttention(_ work: [TaskBoard.Work]) -> [Attention] {
        let loose = work.compactMap { work in work.loose.map { (work, $0.state) } }
            .sorted { ($1.1.createdAt, $0.1.sessionID) < ($0.1.createdAt, $1.1.sessionID) }.map(\.0)
        let tiered = (work.filter { $0.loose == nil } + loose).map { work in
            let pulse = pulse(of: work.agent)
            return (work: work, tier: pulse.steadyTier, running: pulse.tier == .running)
        }
        return [true, false].flatMap { pinned -> [Attention] in
            let tiers = Dictionary(grouping: tiered.filter { ($0.work.item?.task.isPinned == true) == pinned }, by: \.tier)
            return BoardPulse.Tier.allCases.compactMap { tier in tiers[tier].map { (pinned, tier, $0.map { ($0.work, $0.running) }) } }
        }
    }
}
