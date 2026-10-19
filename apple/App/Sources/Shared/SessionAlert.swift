import CueStore
import CueSync
import Foundation

/// 一次要提示的会话转换："等你"或"做完了"。文案与手机锁屏通知同一处（`PiAlertText`）。
struct SessionAlert: Equatable, Identifiable {
    let id = UUID()
    /// 会话记录 id（`PiSessionState.id`）。
    let session: UUID
    let kind: PiAlert
    let title: String
    let question: String?

    init(_ state: PiSessionState, _ kind: PiAlert) {
        session = state.id
        self.kind = kind
        title = state.title
        question = state.question?.text
    }

    var content: (title: String, body: String) { PiAlertText.content(title: title, question: question, kind: kind) }

    var text: Dotted { Dotted(content.title, content.body) }

    var status: PiShown.Status { Self.status(kind) }

    /// 提示带的状态图形与会话状态标同一个（`PiShown.icon`）：等你是赭黄问号圆，做完了是有新回复的铃铛。
    static func status(_ kind: PiAlert) -> PiShown.Status { kind == .waitingForUser ? .asking : .unread }
}

/// 把读到的在线会话（`LiveSessions`，同步来的，本机与别的 Mac 的会话都在）变成要提示你的转换：与上一次读到的版本比
/// （`PiSessionState.alert(since:cue:)`，等 Cue 回答的不算，Mac 置位手机推送标志同一条规则）。两端的提示都只从这里来。
/// 第一次读到某个会话只记下它（规则里没有上一版本就不提示）：App 刚打开时已有的状态不提示。同一个版本读两遍不重复。
/// `since`（iOS）是这次回到前台的时刻：在那之前就发生的转换（冷启动、从后台回来后才同步到的）不补报——那一下系统推送已经提示过，
/// 再在前台弹一遍只会盖在刚点开的页面上。Mac 没有锁屏推送，不给。
struct SessionAlertTracker {
    private var seen: [UUID: PiSessionState] = [:]

    mutating func alerts(for live: [PiSessionListItem], cue: CueDuty?, since active: Date = .distantPast) -> [SessionAlert] {
        defer { seen = Dictionary(live.map { ($0.id, $0.state) }, uniquingKeysWith: { _, last in last }) }
        return live.compactMap { item -> SessionAlert? in
            guard item.state.stateSince >= active else { return nil }
            return item.state.alert(since: seen[item.id], cue: cue).map { SessionAlert(item.state, $0) }
        }
    }
}
