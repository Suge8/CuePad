import CueStore
import Foundation

nonisolated enum Said: Equatable, Sendable {
    case cue(CueMessage, host: String?)
    case request(DeliveryRequest)

    var id: UUID {
        switch self {
        case .cue(let message, _): message.id
        case .request(let request): request.id
        }
    }

    var content: String {
        switch self {
        case .cue(let message, _): message.text
        case .request(let request): request.content
        }
    }

    var host: String? {
        switch self {
        case .cue(_, let host): host
        case .request(let request): request.hostID
        }
    }

    func trip(at moment: Speech.Moment) -> Speech.Trip {
        switch self {
        case .cue(let message, let host):
            Speech.trip(said: message.createdAt, delivered: message.deliveredAt, reachedServer: message.reachedServer, host: host, at: moment)
        case .request(let request): Speech.trip(request, at: moment)
        }
    }

    var roundTrip: Duration? {
        if case .request(let request) = self { request.roundTrip } else { nil }
    }

    var listener: Listener {
        switch self {
        case .cue: .cue
        case .request(let request): .session(request.target, host: request.hostID, mode: request.mode.known ?? .send, card: request.cardID)
        }
    }
}

nonisolated enum Listener: Equatable, Sendable {
    case cue
    case session(SendTarget, host: String, mode: DeliveryMode, card: UUID?)

    static func session(_ session: PiSessionState, mode: DeliveryMode, card: UUID? = nil) -> Listener {
        .session(session.target, host: session.hostID, mode: mode, card: card)
    }
}
