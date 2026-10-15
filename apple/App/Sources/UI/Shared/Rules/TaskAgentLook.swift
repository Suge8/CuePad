/// 交给了会话的叶子任务，在任务页（手机）与任务浮窗（Mac）上此刻是什么样子：哪张吉祥物（Mac 画它）、一句标题、一句说明。
/// 状态只经 `PiShown` 判定，两端同一份说法。
struct TaskAgentLook: Equatable {
    var mascot: Mascot, floats = false, title: String, note: String?

    /// `line`：会话此刻的进展或出错原因（`PiProgress.note`）。
    init(_ shown: PiShown, line: String?) {
        switch shown.status {
        case .working, .delivery, .cueAsking: (mascot, floats, title, note) = (.search, true, shown.status == .cueAsking ? shown.presence : "Agent 正在做", "做完会在这里告诉你")
        case .asking: (mascot, title, note) = (.error, "Agent 在等你\(shown.waitWord)", line)
        case .failed, .restart: (mascot, title, note) = (.error, shown.label, line)
        case .unread: (mascot, title, note) = (.welcome, "Agent 回复了", "去会话里看看")
        case .ended: (mascot, title, note) = (.clean, "会话结束了", "在会话里说一句会把它叫回来")
        case .interrupted: (mascot, title, note) = (.error, "Agent 被打断了", "在会话里说一句，它接着做")
        case .idle, .resting, .fresh, .unknown: (mascot, title, note) = (.welcome, "Agent 歇着", "去会话里接着说")
        }
    }
}
