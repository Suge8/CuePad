#if os(macOS)
import Foundation

/// Mac 的媒体边界只桥接 SDP 与连接事实；授权、上游 call ID、控制通道始终留在 Mac。
final class VoiceRemoteMedia: VoiceMedia {
    let session: VoiceSessionID
    var link: VoiceLink
    /// 手机报过媒体已接通；之前的信令断开直接结束，之后的按 `link` 等手机回来。
    var connected = false
    let offerSDP: String
    let signaling: any VoiceSignaling
    let scope = VoiceOperationScope()
    var onEvent: (VoicePeer.Event) -> Void = { _ in }
    var available = true
    var supportsMute: Bool { false }

    init(header: VoiceSignalHeader, offer: VoiceOffer, signaling: any VoiceSignaling) {
        session = header.session
        link = .bound(local: header.recipient, peer: header.sender)
        offerSDP = offer.sdp
        self.signaling = signaling
    }

    func offer() async throws -> String { try Task.checkCancellation(); return offerSDP }
    func accept(answer: String) async throws {
        guard case .bound(_, let peer) = link else { throw VoiceSignalError.leaseChanged }
        try await scope.perform {
            try await self.signaling.sendVoice(.media(signal: .answer(value: VoiceAnswer(sdp: answer))), session: self.session, to: peer)
        }
    }
    func setMuted(_ muted: Bool) async throws { throw VoiceIssue.busy }

    func close() async { scope.end() }

    func departed(_ reason: VoiceEndReason) {
        available = false
        scope.end()
        onEvent(.ended(reason))
    }
}
#endif
