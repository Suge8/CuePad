#if os(macOS)
import CryptoKit
import Foundation
@testable import CuePad

@MainActor final class LiveSignalPair {
    final class End: VoiceSignaling {
        let local: VoiceEndpoint
        let peer: VoiceEndpoint
        let key: SymmetricKey
        var deliver: (VoiceRelayEvent) async -> Void = { _ in }
        var sequence: UInt32 = 0
        var voiceAvailability: VoiceRelayAvailability { .ready(endpoint: local) }
        var voiceEvents: AsyncStream<VoiceRelayEvent> { AsyncStream { _ in } }
        var liveTunnelKey: SymmetricKey? { key }

        init(local: VoiceEndpoint, peer: VoiceEndpoint, key: SymmetricKey) {
            self.local = local
            self.peer = peer
            self.key = key
        }

        func resolveVoicePeer(_ device: VoiceDeviceID) async throws -> VoiceEndpoint {
            guard device == peer.device else { throw VoiceSignalError.peerUnavailable }
            return peer
        }

        func sendVoice(_ payload: VoiceSignalPayload, session: VoiceSessionID, to recipient: VoiceEndpoint) async throws {
            sequence += 1
            let header = VoiceSignalHeader(version: VoiceSignalFormat.version, sender: local, recipient: recipient, session: session, sequence: sequence,
                                           expiresAtMilliseconds: Int64(Date.now.timeIntervalSince1970 * 1000) + 30_000, purpose: payload.purpose)
            let deliver = deliver
            Task { await deliver(.received(.init(header: header, payload: payload))) }
        }
    }

    let phone: End
    let mac: End

    init(macHost: String) {
        let key = SymmetricKey(size: .bits256)
        let phoneEndpoint = VoiceEndpoint(device: .init("phone-live"), lease: UUID()), macEndpoint = VoiceEndpoint(device: .init(macHost), lease: UUID())
        phone = End(local: phoneEndpoint, peer: macEndpoint, key: key)
        mac = End(local: macEndpoint, peer: phoneEndpoint, key: key)
    }
}
#endif
