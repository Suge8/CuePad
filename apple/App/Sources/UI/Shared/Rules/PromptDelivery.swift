import CueStore
import Foundation

/// 一条提示词发没发出去：只说这句话的投递，不说 Agent 做没做完——Agent 此刻在做什么只写在它的任务那一行（一个任务一个 Agent 会话）。
/// 由窗口那一份交给的会话（`AgentLinks`）推出，不另存。只有没送到的能重发；发出去了就是发出去了，要再说什么写一条新的。
nonisolated enum PromptDelivery: Equatable, Sendable {
    case unsent
    /// 话在路上（请求还没有结果），或正为它开新会话。
    case sending
    /// 这一条的请求没能送达；带原因。
    case failed(String)
    case sent

    /// `handoff` 是它交给的会话（含发给那个会话的最近一条请求）；`launching` 是正为它开新会话。
    init(_ prompt: UUID, handoff: PiSessionListItem?, launching: Bool) {
        if launching { self = .sending; return }
        guard let handoff else { self = .unsent; return }
        // 会话的最近一条请求是这一条的，才看它的结果；别的提示词发到同一会话失败不连累这一条
        if let request = handoff.delivery, request.cardID == prompt {
            if request.isOpen { self = .sending; return }
            if let failure = request.failure { self = .failed(failure); return }
        }
        self = .sent
    }

    init(_ prompt: UUID, agents: AgentLinks) {
        self.init(prompt, handoff: agents.items[prompt], launching: agents.launching.contains(prompt))
    }

    /// 能"发给 Agent"（没发过）或"重发"（没送到）。
    var canSend: Bool {
        switch self {
        case .unsent, .failed: true
        case .sending, .sent: false
        }
    }
}
