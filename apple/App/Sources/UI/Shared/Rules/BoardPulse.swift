import CueStore
import SwiftUI

/// 推进中一张卡此刻的样子（任务卡与没绑任务的会话卡同一条规则）只按这一份分；会话的状态只经 `SessionShown` 判定。
struct BoardPulse: Equatable {
    enum Tier: Int, CaseIterable, Comparable {
        case needsYou, running, resting

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// 卡下沿那条线"现在"那一截：装饰，不对应真实事件。
    enum Trace: Equatable {
        case running(Gait, subagents: Int)
        case stopped(broken: Bool)
        /// 歇着：一条淡线、不带点——横线就是"没在动"。等高的卡下沿不空着，不像没画完。
        case resting
    }

    nonisolated enum Gait: Equatable, Sendable { case think, tool, compact }

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

    var trace: Trace {
        switch tier {
        case .resting: return .resting
        case .needsYou: return .stopped(broken: shown?.status == .interrupted)
        case .running:
            let subagents = session?.runtimeSubagents.count { $0.phase == .known(.running) } ?? 0
            let gait: Gait = switch shown?.status {
            case .working(.tool): .tool
            case .working(.compacting): .compact
            default: .think
            }
            return .running(gait, subagents: subagents)
        }
    }

    func tint(_ palette: Palette) -> Color {
        switch word {
        case .state(let shown): shown.labelTint(palette)
        case .context: palette.failure
        case nil: tier == .running ? palette.signature : palette.ink3
        }
    }

    func lastSaidTint(_ palette: Palette) -> Color {
        tier == .running ? tint(palette) : palette.ink3
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

    /// 置顶的任务在最前：置顶是你亲手定的先后，排在档之前。
    func byAttention(_ work: [TaskBoard.Work]) -> [(pinned: Bool, tier: BoardPulse.Tier, work: [TaskBoard.Work])] {
        let tiered = work.map { (work: $0, tier: pulse(of: $0.agent).tier) }
        return [true, false].flatMap { pinned in
            let tiers = Dictionary(grouping: tiered.filter { ($0.work.item?.task.isPinned == true) == pinned }, by: \.tier)
            return BoardPulse.Tier.allCases.compactMap { tier in tiers[tier].map { (pinned, tier, $0.map(\.work)) } }
        }
    }
}
