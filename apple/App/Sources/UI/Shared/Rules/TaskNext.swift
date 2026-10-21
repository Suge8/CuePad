import CueStore
import Foundation

/// 任务行上"下一步"那一格：一件事此刻要你做什么，最多一个，点了就去那一步（Mac 与手机同一个判断，`Workspace.next(for:)`）。
/// 一个叶子任务一个 Agent 会话：会话那边有事（等你确认、出错、话没送到、有新回复、正在做）就是它，点了打开会话；
/// 叶子还没交给过会话（没绑会话、没在开）就是"开始"，点了把任务的正文作为第一句交给 Agent；都没有就空着。会话的状态只经 `PiShown` 判定。
nonisolated enum TaskNext: Equatable, Sendable {
    case agent(PiShown, session: PiSessionState)
    case start(leaf: Card)

    init?(shown: PiShown?, session: PiSessionState?, startable leaf: Card?) {
        if let shown, let session, Self.wantsLook(shown) {
            self = .agent(shown, session: session)
        } else if let leaf, session == nil {
            self = .start(leaf: leaf)
        } else {
            return nil
        }
    }

    /// 会话这时值得写出来：在跑、在等你、出了事、有你没看的回复。歇着（看过了、新会话、已结束）不写。
    private static func wantsLook(_ shown: PiShown) -> Bool {
        switch shown.status {
        case .delivery, .working, .asking, .awaitsReply, .cueAsking, .failed, .unread, .interrupted: true
        case .idle, .resting, .fresh, .ended, .unknown: false
        }
    }

    /// 会话此刻在做或在等你：完成前要先问一句（完成会把它的会话一起结束）。
    var agentBusy: Bool {
        guard case .agent(let shown, _) = self else { return false }
        switch shown.status {
        case .working, .asking, .delivery: return true
        default: return false
        }
    }

    /// 读屏念的那一格。
    var speech: String {
        switch self {
        case .agent(let shown, _): shown.label
        case .start: "可以开始"
        }
    }
}

extension Workspace {
    /// 一条任务"下一步"那一格（任务行、步骤行都走这里，两端不各自判断）：会话取窗口那一份交给的会话（`agents`，行从环境里取），
    /// Mac 上本机在线的会话换上桥上的实时状态；完成了的不写。有步骤（`steps` 不为 nil）的不是叶子，不开工；正在开会话的不再给"开始"。
    /// `lead`：上级收成一行时（任务看板）此刻干活的叶子（`TaskBoard.Item.leaf`），先看它，它没有"下一步"再看这件自己。
    func next(for task: Card, lead: Card? = nil, in agents: AgentLinks, steps: TaskProgress?) -> TaskNext? {
        if let lead, let next = next(for: lead, in: agents, steps: nil) { return next }
        guard task.status != .done else { return nil }
        let agent = agent(of: task.id, in: agents)
        let startable = steps == nil && !agents.launching.contains(task.id) ? task : nil
        return TaskNext(shown: agent?.shown, session: agent?.session, startable: startable)
    }

    /// 这条任务交给的会话与它此刻显示的状态（不论值不值得写进"下一步"），没交给会话为 nil：
    /// Mac 上本机在线的会话换上桥上的实时状态。"下一步"与推进中的档（`BoardPulse`）都读它。
    func agent(of task: UUID, in agents: AgentLinks) -> (shown: PiShown, session: PiSessionState)? {
        #if os(macOS)
        guard let agent = agents.items[task].map(withLiveState) else { return nil }
        #else
        guard let agent = agents.items[task] else { return nil }
        #endif
        return (shown(agent), agent.state)
    }

    /// 有步骤的任务此刻最该看的那一步的"下一步"：要你动手的会话优先，其次第一个有动静的会话，再次第一个能开始的步骤。
    func lead(of steps: [Card], in agents: AgentLinks) -> TaskNext? {
        let nexts = steps.compactMap { next(for: $0, in: agents, steps: nil) }
        func needsYou(_ next: TaskNext) -> Bool { if case .agent(let shown, _) = next { shown.needsYou } else { false } }
        func agent(_ next: TaskNext) -> Bool { if case .agent = next { true } else { false } }
        return nexts.first(where: needsYou) ?? nexts.first(where: agent) ?? nexts.first
    }
}

extension TaskNext {
    /// 行上写出了状态词（`PiShown.speaksOnTask`）。
    var speaks: Bool { if case .agent(let shown, _) = self { shown.speaksOnTask } else { false } }
    /// 还没交出去的叶子，"开始"。
    var starts: Bool { if case .start = self { true } else { false } }
    /// 会话此刻在跑（圈上那一段走流光）。
    var isRunning: Bool { if case .agent(let shown, _) = self { shown.isRunning } else { false } }
}

extension PiShown {
    /// 任务行上要写出状态词的：要你动手的（`needsYou`），加上停在半路（被打断）与做完一轮你还没看的。在跑的只有会动的线。
    var speaksOnTask: Bool { needsYou || status == .interrupted || status == .unread }
}
