import CueStore
import Foundation

/// 一句说出去的话的记录：对 Cue 说的消息（`host` 是 Cue 运行的那台 Mac），或发给会话的投送请求。气泡、重发、撤回都按它。
nonisolated enum Said: Equatable, Sendable {
    case cue(CueMessage, host: String?)
    case request(DeliveryRequest)

    var id: UUID {
        switch self {
        case .cue(let message, _): message.id
        case .request(let request): request.id
        }
    }

    /// 存储格式正文。
    var content: String {
        switch self {
        case .cue(let message, _): message.text
        case .request(let request): request.content
        }
    }

    /// 接收它的那台 Mac。
    var host: String? {
        switch self {
        case .cue(_, let host): host
        case .request(let request): request.hostID
        }
    }

    func trip(at moment: Speech.Moment) -> Speech.Trip {
        switch self {
        case .cue(let message, let host): Speech.trip(said: message.createdAt, delivered: message.deliveredAt, host: host, at: moment)
        case .request(let request): Speech.trip(request, at: moment)
        }
    }

    /// 往返时间（发给会话的，结果回到本机时才有）。
    var roundTrip: Duration? {
        if case .request(let request) = self { request.roundTrip } else { nil }
    }

    /// 重发写到哪：同一个去处、同样的方式。
    var listener: Listener {
        switch self {
        case .cue: .cue
        case .request(let request): .session(request.target, host: request.hostID, mode: request.mode.known ?? .send, card: request.cardID)
        }
    }
}

/// 说的话写到哪：对 Cue 说（写一条你的消息，Cue 运行的那台 Mac 读到再交给它），或发给一个会话（写一条指定会话所在 Mac 的投送请求）。
nonisolated enum Listener: Equatable, Sendable {
    case cue
    case session(SendTarget, host: String, mode: DeliveryMode, card: UUID?)

    static func session(_ session: PiSessionState, mode: DeliveryMode, card: UUID? = nil) -> Listener {
        .session(session.target, host: session.hostID, mode: mode, card: card)
    }
}
