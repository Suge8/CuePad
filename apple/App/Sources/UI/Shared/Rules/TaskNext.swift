import CueStore
import Foundation

/// 会话的状态只经 `SessionShown` 判定。
nonisolated enum TaskNext: Equatable, Sendable {
    case agent(SessionShown, session: SessionState)
    case start(leaf: Card)

    init?(shown: SessionShown?, session: SessionState?, startable leaf: Card?) {
        if let shown, let session, Self.wantsLook(shown) {
            self = .agent(shown, session: session)
        } else if let leaf, session == nil {
            self = .start(leaf: leaf)
        } else {
            return nil
        }
    }

    private static func wantsLook(_ shown: SessionShown) -> Bool {
        switch shown.status {
        case .delivery, .working, .asking, .awaitsReply, .cueAsking, .failed, .unread, .interrupted, .unknown: true
        case .idle, .resting, .fresh, .ended: false
        }
    }

    var agentBusy: Bool { busySession != nil }

    var busySession: SessionState? {
        guard case .agent(let shown, let session) = self, shown.agentBusy else { return nil }
        return session
    }

    var speech: String {
        switch self {
        case .agent(let shown, _): shown.label
        case .start: String(localized: "可以开始")
        }
    }
}

extension Workspace {
    /// 任务行、子任务行都走这里，两端不各自判断。看板的卡不走这里（`next(for item:)`）。
    func next(for task: Card, in agents: AgentLinks, steps: TaskProgress?) -> TaskNext? {
        guard task.status != .done else { return nil }
        let agent = agent(of: task.id, in: agents)
        let startable = steps == nil && !isLaunching(task.id, in: agents) ? task : nil
        return TaskNext(shown: agent?.shown, session: agent?.session, startable: startable)
    }

    func next(for item: TaskBoard.Item, shown: SessionShown?) -> TaskNext? {
        guard item.task.status != .done else { return nil }
        return TaskNext(shown: shown, session: item.agent?.state, startable: item.reaching ? nil : item.leaf)
    }

    /// 不论值不值得写进"下一步"。
    func agent(of task: UUID, in agents: AgentLinks) -> (shown: SessionShown, session: SessionState)? {
        #if os(macOS)
        guard let agent = agents.items[task].map(withLiveState) else { return nil }
        #else
        guard let agent = agents.items[task] else { return nil }
        #endif
        return (shown(agent), agent.state)
    }

    func lead(of steps: [Card], in agents: AgentLinks) -> TaskNext? {
        let nexts = steps.compactMap { next(for: $0, in: agents, steps: nil) }
        func needsYou(_ next: TaskNext) -> Bool { if case .agent(let shown, _) = next { shown.needsYou } else { false } }
        func agent(_ next: TaskNext) -> Bool { if case .agent = next { true } else { false } }
        return nexts.first(where: needsYou) ?? nexts.first(where: agent) ?? nexts.first
    }
}

extension TaskNext {
    var speaks: Bool { if case .agent(let shown, _) = self { shown.speaksOnTask } else { false } }
    var starts: Bool { if case .start = self { true } else { false } }
    var isRunning: Bool { if case .agent(let shown, _) = self { shown.isRunning } else { false } }
}

extension SessionShown {
    var speaksOnTask: Bool {
        if case .unknown = status { return true }
        return needsYou || status == .interrupted || status == .unread
    }
}
