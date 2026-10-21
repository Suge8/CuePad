import CueStore
import Foundation

/// 会话行状态词后面的读数（全 App 的会话行同一份，`PiSessionRow`）：一个此刻的短词（`Note`）、子代理（窄处的行）、快满的上下文。
/// 已结束的会话只有短词。
nonisolated struct PiRowFacts: Equatable {
    var note: Note?
    var subagents: PiSubagentSummary?
    /// 上下文用到七成（`PiContextMeter.tightFraction`）起才有：余量足或刚压缩完不知道用量时，行上不写。
    var context: PiContextMeter?

    /// 状态词后的短词，先后：正在结束 → 没能结束 → 没能改名 → 你的话在路上（会话在跑时）→ 正在改名 → 有草稿。
    enum Note: Equatable {
        case ending, endFailed, renameFailed, renaming, draft
        case transit(String)

        var text: String {
            switch self {
            case .ending: "正在结束…"
            case .endFailed: "没能结束"
            case .renameFailed: "没能改名"
            case .renaming: "正在改名"
            case .draft: "有草稿"
            case .transit(let text): text
            }
        }

        var isFailure: Bool { self == .endFailed || self == .renameFailed }
    }

    /// `end` 是此刻要显示的那次结束到哪了（`DeliveryRequest.shownEnd`），`renaming`、`renameFailed` 由最近一条改名推出（`PiRename`），
    /// `hasDraft` 是回复框里有没发的草稿。
    init(_ session: PiSessionState, shown: PiShown, end: Speech.Trip?, renaming: Bool, renameFailed: Bool, hasDraft: Bool) {
        note = if end == .sending { .ending }
            else if end?.failure != nil { .endFailed }
            else if renameFailed { .renameFailed }
            else if let transit = shown.note { .transit(transit) }
            else if renaming { .renaming }
            else if hasDraft { .draft }
            else { nil }
        guard session.state != .known(.ended) else { return }
        subagents = PiSubagentSummary(session.subagents)
        context = session.context.flatMap(PiContextMeter.init).flatMap { $0.level == .roomy ? nil : $0 }
    }
}

extension AppSettings {
    /// 这个会话在本机的行上写的读数：显示状态（`shown`）、本机看没看过改名失败、回复框草稿都从本机偏好来。
    func facts(_ session: PiSessionState, shown: PiShown, end: Speech.Trip?, rename: DeliveryRequest?, at moment: Speech.Moment) -> PiRowFacts {
        PiRowFacts(
            session, shown: shown, end: end, renaming: PiRename.isPending(rename, at: moment),
            renameFailed: PiRename.failed(rename, seen: sessionSeen[session.sessionID], at: moment), hasDraft: draftPreview(for: session.id) != nil)
    }
}

