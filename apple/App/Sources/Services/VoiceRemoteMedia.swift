#if os(macOS)
import Foundation

/// Mac 的媒体边界只桥接 SDP 与连接事实；授权、上游 call ID、控制通道始终留在 Mac。
final class VoiceRemoteMedia: VoiceMedia {
    let header: VoiceSignalHeader
    let offerSDP: String
    let signaling: any VoiceSignaling
    let scope = VoiceOperationScope()
    var onEvent: (VoicePeer.Event) -> Void = { _ in }
    var available = true
    var supportsMute: Bool { false }

    init(header: VoiceSignalHeader, offer: VoiceOffer, signaling: any VoiceSignaling) {
        self.header = header
        offerSDP = offer.sdp
        self.signaling = signaling
    }

    func offer() async throws -> String { try Task.checkCancellation(); return offerSDP }
    func accept(answer: String) async throws {
        try await scope.perform {
            try await self.signaling.sendVoice(.media(signal: .answer(value: VoiceAnswer(sdp: answer))),
                                               session: self.header.session, to: self.header.sender)
        }
    }
    func play() async throws { throw VoiceIssue.busy }
    func setMuted(_ muted: Bool) async throws { throw VoiceIssue.busy }

    func close() async throws {
        scope.end()
    }

    func departed(_ reason: VoiceEndReason) {
        available = false
        scope.end()
        onEvent(.ended(reason))
    }
}
#endif
