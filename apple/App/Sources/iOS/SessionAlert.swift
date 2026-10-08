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

    var text: String {
        let content = PiAlertText.content(title: title, question: question, kind: kind)
        return "\(content.title) · \(content.body)"
    }

    var symbol: String { kind == .waitingForUser ? "questionmark.bubble.fill" : "checkmark.circle.fill" }
}

/// 把读到的在线会话变成要提示的转换：与上一次读到的版本比（`PiSessionState.alert(since:)`，Mac 置位推送标志同一条规则）。
/// 第一次读到只记基线：App 刚打开时已有的状态不提示。同一个版本读两遍不重复。
struct SessionAlertTracker {
    private var seen: [UUID: PiSessionState]?

    mutating func alerts(for live: [PiSessionState]) -> [SessionAlert] {
        defer { seen = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }) }
        guard let seen else { return [] }
        return live.compactMap { state in state.alert(since: seen[state.id]).map { SessionAlert(state, $0) } }
    }
}
#endif
