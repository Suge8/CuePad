/// 交给了会话的叶子任务，在任务气泡最下面那一条上此刻怎么说：一句标题、一句说明。
/// 状态只经 `PiShown` 判定，两端同一份说法。说明不复述右边的"去会话"：只是叫你去会话里看、回、接着说的，不写。
struct TaskAgentLook: Equatable {
    var title: String, note: String?

    /// `line`：会话此刻的进展或出错原因（`PiProgress.note`）。
    init(_ shown: PiShown, line: String?) {
        switch shown.status {
        case .delivery(.failed): (title, note) = (shown.label, line)
        case .working, .delivery, .cueAsking:
            (title, note) = shown.isRunning
                ? (String(localized: "Agent 正在做"), String(localized: "做完会在这里告诉你")) : (shown.presence, nil)
        case .asking: (title, note) = (shown.asksForWords ? String(localized: "Agent 在等你回答") : String(localized: "Agent 在等你确认"), line)
        case .awaitsReply: (title, note) = (shown.presence, nil)
        case .failed: (title, note) = (shown.label, line)
        case .unread: (title, note) = (String(localized: "Agent 回复了"), nil)
        case .ended: (title, note) = (String(localized: "会话结束了"), String(localized: "在会话里说一句会把它叫回来"))
        case .interrupted: (title, note) = (String(localized: "Agent 被打断了"), String(localized: "在会话里说一句，它接着做"))
        case .unknown: (title, note) = (shown.presence, nil)
        case .idle, .resting, .fresh: (title, note) = (String(localized: "Agent 歇着"), nil)
        }
    }
}
