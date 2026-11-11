import CueStore
import CueSync
import Foundation

/// 到不到你由 `CueStore.reaches` 定。文案与手机锁屏通知同一处（`AlertText`）。
struct SessionAlert: Equatable, Identifiable {
    let id = UUID()
    let session: UUID
    let kind: AlertKind
    let title: String
    let question: String?
    let reply: String?
    let failure: String?

    init(_ state: SessionState, _ kind: AlertKind) {
        session = state.id
        self.kind = kind
        title = state.title
        question = state.question?.text
        reply = state.lastReply
        failure = state.state == .known(.error) ? state.detail : nil
    }

    var content: (title: String, body: String) {
        AlertText.content(title: title, question: question, reply: reply, failure: failure, kind: kind)
    }

    var text: Dotted { Dotted("\(content.title)：\(content.body)") }

    var status: SessionShown.Status { Self.status(kind) }

    /// 与会话状态标同一个图形（`SessionShown.icon`）。
    static func status(_ kind: AlertKind) -> SessionShown.Status {
        switch kind {
        case .waitingForUser: .asking
        case .awaitsReply: .awaitsReply
        case .settled: .unread
        }
    }
}

/// 两端的提示都只从这里来：读到的在线会话（`LiveSessions`）与上一次比出的状态转换（`SessionState.alert(since:)`，Mac 置位手机推送标志同一条规则），与 Cue 刚留给你回的停下（`CueDuty.leftToYou`，状态没变）。
/// 同一次读到两样时报留给你的那一下：它说得更准。到不到你由消费的一方问 `CueStore.reaches`。
/// 第一次读到某个会话只记下它（规则里没有上一版本就不提示）：App 刚打开时已有的状态不提示。同一个版本读两遍不重复。
/// `since`（iOS）是这次回到前台的时刻：在那之前就发生的转换（冷启动、从后台回来后才同步到的）不补报——那一下系统推送已经提示过，
/// 再在前台弹一遍只会盖在刚点开的页面上。Mac 没有锁屏推送，不给。
struct SessionAlertTracker {
    private var seen: [UUID: SessionState] = [:]
    private var left: Set<UUID> = []

    mutating func alerts(for live: [SessionListItem], cue: CueDuty?, since active: Date = .distantPast) -> [SessionAlert] {
        let nowLeft = Set(live.filter { cue?.leftToYou($0.state) == true }.map(\.id))
        defer {
            seen = Dictionary(live.map { ($0.id, $0.state) }, uniquingKeysWith: { _, last in last })
            left = nowLeft
        }
        return live.compactMap { item -> SessionAlert? in
            guard let previous = seen[item.id] else { return nil }
            if nowLeft.contains(item.id), !left.contains(item.id) {
                return SessionAlert(item.state, item.state.leftAlert)
            }
            guard item.state.stateSince >= active, let kind = item.state.alert(since: previous) else { return nil }
            return SessionAlert(item.state, kind)
        }
    }
}
