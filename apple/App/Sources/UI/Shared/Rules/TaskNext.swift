import CueStore

/// 任务行行尾那一格"下一步"：一件事此刻要你做什么，最多一个，点了就去那一步。一个叶子任务一个 Agent 会话：
/// 会话那边有事（等你确认、出错、话没送到、有新回复、正在做）就是它，点了打开会话；否则写好了还没开始就是"写好了"，
/// 点了打开任务浮窗；都没有就空着。会话的状态只经 `PiShown` 判定。
nonisolated enum TaskNext: Equatable, Sendable {
    case agent(PiShown, sessionID: String)
    case draft

    init?(shown: PiShown?, sessionID: String?, hasDraft: Bool) {
        if let shown, let sessionID, Self.wantsLook(shown) {
            self = .agent(shown, sessionID: sessionID)
        } else if hasDraft {
            self = .draft
        } else {
            return nil
        }
    }

    /// 会话这时值得写出来：在跑、在等你、出了事、有你没看的回复。歇着（看过了、新会话、已结束）不写。
    static func wantsLook(_ shown: PiShown) -> Bool {
        switch shown.status {
        case .delivery, .working, .asking, .failed, .restart, .unread: true
        case .idle, .resting, .fresh, .ended, .unknown: false
        }
    }
}
