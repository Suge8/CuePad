struct TaskAgentLook: Equatable {
    var title: String, note: String?

    init(_ shown: SessionShown, line: String?) {
        switch shown.status {
        case .delivery(.failed): (title, note) = (shown.label, line)
        case .working, .delivery, .cueAsking:
            (title, note) = shown.isRunning
                ? (String(localized: "Agent 正在做"), String(localized: "做完会在这里告诉你")) : (shown.presence, nil)
        case .asking: (title, note) = (String(localized: "Agent 在等你回答"), line)
        case .awaitsReply, .unread: (title, note) = (String(localized: "Agent 回复了"), nil)
        case .failed: (title, note) = (shown.label, line)
        case .ended: (title, note) = (String(localized: "会话休眠了"), String(localized: "在会话里说一句会把它叫回来"))
        case .interrupted: (title, note) = (String(localized: "Agent 被打断了"), String(localized: "在会话里说一句，它接着做"))
        case .unknown, .offline: (title, note) = (shown.presence, nil)
        case .idle, .resting, .fresh: (title, note) = (String(localized: "Agent 空闲"), nil)
        }
    }
}
