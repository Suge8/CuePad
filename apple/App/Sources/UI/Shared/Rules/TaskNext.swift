import CueStore

/// 任务行上"下一步"那一格：一件事此刻要你做什么，最多一个，点了就去那一步（Mac 与手机同一个判断，`Workspace.next(for:)`）。
/// 一个叶子任务一个 Agent 会话：会话那边有事（等你确认、出错、话没送到、有新回复、正在做）就是它，点了打开会话；
/// 否则写好了草稿还没交出去就是"开始"，点了把草稿交给 Agent；都没有就空着。会话的状态只经 `PiShown` 判定。
nonisolated enum TaskNext: Equatable, Sendable {
    case agent(PiShown, session: PiSessionState)
    case start(draft: Card)

    init?(shown: PiShown?, session: PiSessionState?, draft: Card?) {
        if let shown, let session, Self.wantsLook(shown) {
            self = .agent(shown, session: session)
        } else if let draft {
            self = .start(draft: draft)
        } else {
            return nil
        }
    }

    /// 会话这时值得写出来：在跑、在等你、出了事、有你没看的回复。歇着（看过了、新会话、已结束）不写。
    private static func wantsLook(_ shown: PiShown) -> Bool {
        switch shown.status {
        case .delivery, .working, .asking, .cueAsking, .failed, .restart, .unread, .interrupted: true
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
        case .start: "写好了，可以开始"
        }
    }
}

extension Workspace {
    /// 一条任务"下一步"那一格（任务行、步骤行都走这里，两端不各自判断）：会话取窗口那一份交给的会话（`AgentLinks`），
    /// Mac 上本机在线的会话换上桥上的实时状态；完成了的不写。
    func next(for task: Card, agent: PiSessionListItem?, draft: Card?) -> TaskNext? {
        guard task.status != .done else { return nil }
        #if os(macOS)
        let agent = agent.map(withLiveState)
        #endif
        return TaskNext(shown: agent.map(shown), session: agent?.state, draft: draft)
    }
}
