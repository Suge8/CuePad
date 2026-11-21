import CueStore
import SwiftUI

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

    typealias Attention = (pinned: Bool, tier: BoardPulse.Tier, work: [(work: TaskBoard.Work, running: Bool)])

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
