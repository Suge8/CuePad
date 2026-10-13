import CueStore
import Foundation

/// 会话行状态词后面的读数（全 App 的会话行同一份，`PiSessionRow`）：一个此刻的短词（`Note`）、子代理、上下文用了多少、会话自己的模型。
/// 只写看得见的状态，不写会话在说什么——那在会话页里。已结束的会话没有读数（历史里只看名字与所在）。
nonisolated struct PiRowFacts: Equatable {
    var note: Note?
    var subagents: PiSubagentSummary?
    var context: PiContextMeter?
    var model: String?

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

    /// `end` 是此刻要显示的结束请求（`DeliveryRequest.shownEnd`），`renaming`、`renameFailed` 由最近一条改名推出（`PiRename`），
    /// `hasDraft` 是回复框里有没发的草稿。
    init(_ session: PiSessionState, shown: PiShown, end: DeliveryRequest?, renaming: Bool, renameFailed: Bool, hasDraft: Bool) {
        note = if end?.isOpen == true { .ending }
            else if end?.failure != nil { .endFailed }
            else if renameFailed { .renameFailed }
            else if let transit = shown.note { .transit(transit) }
            else if renaming { .renaming }
            else if hasDraft { .draft }
            else { nil }
        guard session.state != .known(.ended) else { return }
        subagents = PiSubagentSummary(session.subagents)
        context = session.context.flatMap(PiContextMeter.init)
        model = session.model.map { PiModelName.short($0.key.id) }
    }
}

extension AppSettings {
    /// 这个会话在本机的行上写的读数：显示状态（`shown`）、本机看没看过改名失败、回复框草稿都从本机偏好来。
    func facts(_ session: PiSessionState, shown: PiShown, end: DeliveryRequest?, rename: DeliveryRequest?) -> PiRowFacts {
        PiRowFacts(
            session, shown: shown, end: end, renaming: PiRename.isPending(rename),
            renameFailed: PiRename.failed(rename, seen: sessionSeen[session.sessionID]), hasDraft: draftPreview(for: session.id) != nil)
    }
}

/// 模型的短名（会话行、子代理）：去掉提供方、开头的厂商词与末尾的日期版本，"anthropic/claude-opus-5-5-20260901" 写成 "opus-5-5"。
nonisolated enum PiModelName {
    static func short(_ model: String) -> String {
        let id = (model.split(separator: "/").last.map(String.init) ?? model).replacing(/-\d{8}$/, with: "")
        return vendorPrefixes.lazy.compactMap { id.hasPrefix($0) && id.count > $0.count ? String(id.dropFirst($0.count)) : nil }.first ?? id
    }

    private static let vendorPrefixes = ["claude-"]
}
