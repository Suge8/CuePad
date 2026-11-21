import Foundation
import Observation

nonisolated enum VoiceTiming {
    static let connection: Duration = .seconds(30)
    static let send: Duration = .seconds(2)
    static let relinkGrace: Duration = .seconds(15)
}

@Observable final class VoiceLeg {
    let session: VoiceSessionID
    var link: VoiceLink?
    var connected = false
    @ObservationIgnored let scope = VoiceOperationScope()
    @ObservationIgnored var depart: (VoiceEndReason) async -> Void = { _ in }

    init(session: VoiceSessionID, link: VoiceLink? = nil) {
        self.session = session
        self.link = link
    }

    func carries(local: VoiceEndpoint?, peer: VoiceEndpoint?) -> Bool {
        guard case .bound(let bound, let other)? = link else { return false }
        return (local == nil || bound == local) && (peer == nil || other == peer)
    }

    func closed(_ reason: VoiceEndReason, signaling: (any VoiceSignaling)?, canWait: Bool = true) async {
        guard case .bound(_, let peer)? = link else { return }
        if connected, canWait, VoiceLink.canRelink(after: reason), let signaling { return relink(peer.device, reason: reason, signaling: signaling) }
        await depart(reason)
    }

    func rebind(_ header: VoiceSignalHeader) -> Bool {
        guard header.session == session, let link, header.sender.device == link.peerDevice else { return false }
        let pair = VoiceLink.bound(local: header.recipient, peer: header.sender)
        guard link != pair else { return false }
        self.link = pair
        return true
    }

    private func relink(_ peer: VoiceDeviceID, reason: VoiceEndReason, signaling: any VoiceSignaling) {
        let until = ContinuousClock.now + VoiceTiming.relinkGrace
        link = .relinking(peer: peer, until: until, reason: reason)
        AppServices.log.notice("Voice signaling lost (\(reason.rawValue, privacy: .public)), waiting for the peer")
        scope.spawn { [self] in
            await Self.reach(peer, until: until, signaling: signaling, done: { self.link?.isBound == true }) { signaling, endpoint in
                try await signaling.sendVoice(.media(signal: .resume(ask: true)), session: self.session, to: endpoint)
            }
            guard link?.isBound == false, !Task.isCancelled else { return }
            await depart(reason)
        }
    }

    static func reach(_ device: VoiceDeviceID, until: ContinuousClock.Instant, signaling: any VoiceSignaling, done: () -> Bool,
                      send: @escaping (any VoiceSignaling, VoiceEndpoint) async throws -> Void) async {
        while !done(), !Task.isCancelled, ContinuousClock.now < until {
            if case .ready = signaling.voiceAvailability {
                let attempt = VoiceOperationScope()
                do { try await attempt.perform(within: until - .now) { try await send(signaling, try await signaling.resolveVoicePeer(device)) } }
                catch { AppServices.log.info("Voice relink attempt: \(String(describing: error), privacy: .public)") }
                attempt.end()
            }
            guard !done() else { return }
            try? await Task.sleep(until: min(.now + .seconds(1), until), clock: .continuous)
        }
    }
}
