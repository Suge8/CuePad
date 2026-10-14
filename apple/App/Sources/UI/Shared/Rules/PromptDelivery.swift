import CueStore
import Foundation

/// 一条提示词发没发出去。提示词是准备发给任务那个 Agent 会话的话：确认送达就用掉了（资料库里删掉，原话在会话里），
/// 所以还在任务里的提示词只有三种——没发、发送中、没送到（`Speech` 的规则，含过了时限没回执）。Agent 此刻在做什么写在任务那一行，不在这里。
/// 由窗口那一份交给的会话（`AgentLinks`）与此刻推出，不另存。
nonisolated enum PromptDelivery: Equatable, Sendable {
    case unsent
    /// 话在路上（这一条的请求还没回执），或正为它开新会话。
    case sending
    /// 这一条的请求没能送达，带着它与原因。只有它能重发：重发前先撤回它（没被 Mac 领取的，免得 Mac 回来再发一遍）。
    case failed(DeliveryRequest, Speech.Failure)

    /// `handoff` 是它交给的会话（含发给那个会话的最近一条请求）；`launching` 是正为它开新会话；`moment` 是此刻（`AppServices.speech`）。
    init(_ prompt: UUID, handoff: PiSessionListItem?, launching: Bool, at moment: Speech.Moment) {
        if launching { self = .sending; return }
        guard let request = Self.request(of: prompt, handoff: handoff) else { self = .unsent; return }
        switch Speech.trip(request, at: moment) {
        case .sending: self = .sending
        case .delivered: self = .unsent
        case .failed(let failure): self = .failed(request, failure)
        }
    }

    init(_ prompt: UUID, agents: AgentLinks, at moment: Speech.Moment) {
        self.init(prompt, handoff: agents.items[prompt], launching: agents.launching.contains(prompt), at: moment)
    }

    /// 会话的最近一条请求是这一条的，才看它的结果；别的提示词发到同一会话失败不连累这一条。
    private static func request(of prompt: UUID, handoff: PiSessionListItem?) -> DeliveryRequest? {
        guard let request = handoff?.delivery, request.cardID == prompt else { return nil }
        return request
    }

    /// 能"发给 Agent"（没发过）或"重发"（没送到）。
    var canSend: Bool { self != .sending }
}
