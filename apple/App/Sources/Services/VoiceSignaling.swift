import CryptoKit
import Foundation

nonisolated enum VoiceRelayRequest: Equatable, Codable, Sendable {
    case register(claim: VoiceRegistrationClaim, signature: Data)
    case resolve(request: UUID, device: VoiceDeviceID)
    case signal(packet: VoiceSealedSignal)
}

nonisolated struct VoiceRegistrationClaim: Equatable, Codable, Sendable {
    let version: UInt8
    let room: String
    let challenge: String
    let device: VoiceDeviceID
    let lease: UUID

    init(room: String, challenge: String, device: VoiceDeviceID) {
        version = VoiceSignalFormat.version
        self.room = room
        self.challenge = challenge
        self.device = device
        lease = UUID()
    }

    var endpoint: VoiceEndpoint { VoiceEndpoint(device: device, lease: lease) }

    func signatureInput() throws -> Data {
        try Data((VoiceSignalFormat.registrationContext + "\n").utf8) + VoiceSignalFormat.canonicalJSON(self)
    }
}

nonisolated enum VoiceRelayResponse: Equatable, Codable, Sendable {
    case registered(endpoint: VoiceEndpoint)
    case resolved(request: UUID, endpoint: VoiceEndpoint)
    case unavailable(request: UUID, device: VoiceDeviceID)
    case departed(endpoint: VoiceEndpoint, reason: VoicePeerDeparture)
    case signal(packet: VoiceSealedSignal)
    case rejected(header: VoiceSignalHeader, reason: VoiceSignalRejection)
}

nonisolated enum VoicePeerDeparture: String, Codable, Sendable { case disconnected, replaced }
nonisolated enum VoiceSignalRejection: String, Codable, Sendable { case leaseMismatch, unavailable, tooLarge, invalid }

nonisolated enum VoiceRelayAvailability: Equatable, Sendable {
    case unavailable
    case unsupported
    case ready(endpoint: VoiceEndpoint)
}

nonisolated enum VoiceRelayEvent: Equatable, Sendable {
    case availability(VoiceRelayAvailability)
    case localClosed(endpoint: VoiceEndpoint, reason: VoiceEndReason)
    case peerClosed(endpoint: VoiceEndpoint, reason: VoicePeerDeparture)
    case received(VoiceReceivedSignal)
    case rejected(header: VoiceSignalHeader, reason: VoiceSignalRejection)
    case unreadable(header: VoiceSignalHeader)
}

nonisolated enum VoiceSignalError: Error {
    case unavailable, unsupported, peerUnavailable, leaseChanged, expired, tooLarge, invalid, unreadable
    case rejected(VoiceSignalRejection)
}

nonisolated enum VoiceLink: Equatable, Sendable {
    case bound(local: VoiceEndpoint, peer: VoiceEndpoint)
    case relinking(peer: VoiceDeviceID, until: ContinuousClock.Instant, reason: VoiceEndReason)

    var peerDevice: VoiceDeviceID {
        switch self {
        case .bound(_, let peer): peer.device
        case .relinking(let peer, _, _): peer
        }
    }

    var isBound: Bool { if case .bound = self { true } else { false } }

    static func canRelink(after reason: VoiceEndReason) -> Bool { [.networkFailed, .peerLeft, .leaseReplaced].contains(reason) }
}

@MainActor protocol VoiceSignaling: AnyObject {
    var voiceAvailability: VoiceRelayAvailability { get }
    var voiceEvents: AsyncStream<VoiceRelayEvent> { get }

    func resolveVoicePeer(_ device: VoiceDeviceID) async throws -> VoiceEndpoint
    func sendVoice(_ payload: VoiceSignalPayload, session: VoiceSessionID, to recipient: VoiceEndpoint) async throws
    var liveTunnelKey: SymmetricKey? { get }
}
