import CueStore
import CueSync
import Foundation

/// 一件可能要提示的会话动静："等你"、"待回复"或"做完了"（到不到你由 `CueStore.reaches` 定）。文案与手机锁屏通知同一处（`PiAlertText`）。
struct SessionAlert: Equatable, Identifiable {
    let id = UUID()
    /// 会话记录 id（`PiSessionState.id`）。
    let session: UUID
    let kind: PiAlert
    let title: String
    let question: String?
    let reply: String?

    init(_ state: PiSessionState, _ kind: PiAlert) {
        session = state.id
        self.kind = kind
        title = state.title
        question = state.question?.text
        reply = state.lastReply
    }

    var content: (title: String, body: String) { PiAlertText.content(title: title, question: question, reply: reply, kind: kind) }

    var text: Dotted { Dotted(content.title, content.body) }

    var status: PiShown.Status { Self.status(kind) }

    /// 提示带的状态图形与会话状态标同一个（`PiShown.icon`）：等你是赭黄问号圆，待回复同会话行的待回复，做完了是有新回复的铃铛。
    static func status(_ kind: PiAlert) -> PiShown.Status {
        switch kind {
        case .waitingForUser: .asking
        case .awaitsReply: .awaitsReply
        case .settled: .unread
        }
    }
}

/// 把读到的在线会话（`LiveSessions`，同步来的，本机与别的 Mac 的会话都在）变成可能要提示的动静，两端的提示都只从这里来：
/// 与上一次读到的版本比出的状态转换（`PiSessionState.alert(since:)`，Mac 置位手机推送标志同一条规则），与 Cue 刚留给你回的停下
/// （`CueDuty.leftToYou`，状态没变；歇着的算待回复，在等回答的算等你，同 `CueStore.flagLeftToYou`）。同一次读到两样时报留给你的那一下：它说得更准。到不到你由消费的一方问 `CueStore.reaches`。
/// 第一次读到某个会话只记下它（规则里没有上一版本就不提示）：App 刚打开时已有的状态不提示。同一个版本读两遍不重复。
/// `since`（iOS）是这次回到前台的时刻：在那之前就发生的转换（冷启动、从后台回来后才同步到的）不补报——那一下系统推送已经提示过，
/// 再在前台弹一遍只会盖在刚点开的页面上。Mac 没有锁屏推送，不给。
struct SessionAlertTracker {
    private var seen: [UUID: PiSessionState] = [:]
    private var left: Set<UUID> = []

    mutating func alerts(for live: [PiSessionListItem], cue: CueDuty?, since active: Date = .distantPast) -> [SessionAlert] {
        let nowLeft = Set(live.filter { cue?.leftToYou($0.state) == true }.map(\.id))
        defer {
            seen = Dictionary(live.map { ($0.id, $0.state) }, uniquingKeysWith: { _, last in last })
            left = nowLeft
        }
        return live.compactMap { item -> SessionAlert? in
            guard let previous = seen[item.id] else { return nil }
            if nowLeft.contains(item.id), !left.contains(item.id) {
                return SessionAlert(item.state, item.state.state == .known(.settled) ? .awaitsReply : .waitingForUser)
            }
            guard item.state.stateSince >= active, let kind = item.state.alert(since: previous) else { return nil }
            return SessionAlert(item.state, kind)
        }
    }
}
