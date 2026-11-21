#if os(macOS)
import Foundation

final class VoiceRemoteMedia: VoiceMedia {
    let leg: VoiceLeg
    var results: [VoiceCommand.ID: VoiceCommandResult.Outcome] = [:]
    let offerSDP: String
    let signaling: any VoiceSignaling
    var onEvent: (VoicePeer.Event) -> Void = { _ in }
    var available = true
    var supportsMute: Bool { false }

    init(header: VoiceSignalHeader, offer: VoiceOffer, signaling: any VoiceSignaling) {
        leg = VoiceLeg(session: header.session, link: .bound(local: header.recipient, peer: header.sender))
        offerSDP = offer.sdp
        self.signaling = signaling
        leg.depart = { [weak self] in self?.departed($0) }
    }

    func offer() async throws -> String { try Task.checkCancellation(); return offerSDP }
    func accept(answer: String) async throws {
        guard case .bound(_, let peer)? = leg.link else { throw VoiceSignalError.leaseChanged }
        try await leg.scope.perform {
            try await self.signaling.sendVoice(.media(signal: .answer(value: VoiceAnswer(sdp: answer))), session: self.leg.session, to: peer)
        }
    }
    func setMuted(_ muted: Bool) async throws { throw VoiceIssue.busy }

    func close() async { leg.scope.end() }

    func departed(_ reason: VoiceEndReason) {
        available = false
        leg.scope.end()
        onEvent(.ended(reason))
    }
}
#endif
