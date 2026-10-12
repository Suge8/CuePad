import CueStore
import Foundation

/// 一条提示词发没发出去。提示词是准备发给任务那个 Agent 会话的话：确认送达就用掉了（资料库里删掉，原话在会话里），
/// 所以还在任务里的提示词只有三种——没发、发送中、没送到。Agent 此刻在做什么写在任务那一行，不在这里。
/// 由窗口那一份交给的会话（`AgentLinks`）推出，不另存。
nonisolated enum PromptDelivery: Equatable, Sendable {
    case unsent
    /// 话在路上（这一条的请求还没有结果），或正为它开新会话。
    case sending
    /// 这一条的请求没能送达；带原因。只有它能重发。
    case failed(String)

    /// `handoff` 是它交给的会话（含发给那个会话的最近一条请求）；`launching` 是正为它开新会话。
    init(_ prompt: UUID, handoff: PiSessionListItem?, launching: Bool) {
        if launching { self = .sending; return }
        // 会话的最近一条请求是这一条的，才看它的结果；别的提示词发到同一会话失败不连累这一条
        guard let request = handoff?.delivery, request.cardID == prompt else { self = .unsent; return }
        if request.isOpen { self = .sending } else if let failure = request.failure { self = .failed(failure) } else { self = .unsent }
    }

    init(_ prompt: UUID, agents: AgentLinks) {
        self.init(prompt, handoff: agents.items[prompt], launching: agents.launching.contains(prompt))
    }

    /// 能"发给 Agent"（没发过）或"重发"（没送到）。
    var canSend: Bool { self != .sending }
}
