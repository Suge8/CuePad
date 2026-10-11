#if os(iOS)
import CueStore
import CueSync
import Foundation

/// 一次要在前台提示的会话转换："等你确认"或"做完了"。文案与锁屏通知同一处（`PiAlertText`）。
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

    var text: Dotted {
        let content = PiAlertText.content(title: title, question: question, kind: kind)
        return Dotted(content.title, content.body)
    }

    var symbol: String { kind == .waitingForUser ? "questionmark.bubble.fill" : "checkmark.circle.fill" }
}

/// 把读到的在线会话变成要提示的转换：与上一次读到的版本比（`PiSessionState.alert(since:)`，Mac 置位推送标志同一条规则）。
/// 第一次读到某个会话只记下它（规则里没有上一版本就不提示）：App 刚打开时已有的状态不提示。同一个版本读两遍不重复。
/// `since` 是这次回到前台的时刻：在那之前就发生的转换（冷启动、从后台回来后才同步到的）不补报——那一下系统推送已经提示过，
/// 再在前台弹一遍只会盖在刚点开的页面上。
struct SessionAlertTracker {
    private var seen: [UUID: PiSessionState] = [:]

    mutating func alerts(for live: [PiSessionState], since active: Date) -> [SessionAlert] {
        defer { seen = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }) }
        return live.compactMap { state in
            guard state.stateSince >= active else { return nil }
            return state.alert(since: seen[state.id]).map { SessionAlert(state, $0) }
        }
    }
}
#endif
