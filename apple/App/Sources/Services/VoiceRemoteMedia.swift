#if os(macOS)
import Foundation

/// Mac 的媒体边界只桥接 SDP 与连接事实；授权、上游 call ID、控制通道始终留在 Mac。
final class VoiceRemoteMedia: VoiceMedia {
    let leg: VoiceLeg
    /// 这一通里手机发来的命令的结果：发给手机当前的租约，换绑后按原命令身份再补送一遍（手机按命令 ID 认，没在等的丢掉），不重新执行。
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

    /// 手机离开（挂断、媒体结束、宽限期满没回来）：这一路的等待停下，通话按这个原因结束
    func departed(_ reason: VoiceEndReason) {
        available = false
        leg.scope.end()
        onEvent(.ended(reason))
    }
}
#endif
