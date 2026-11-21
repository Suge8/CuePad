#if os(iOS)
import Foundation
import Observation
import UIKit

@Observable final class VoicePhoneSession {
    let leg: VoiceLeg
    let dialed: VoiceEndpoint
    let media: any VoiceMedia
    var answered = false
    @ObservationIgnored var deadline: Task<Void, Never>?
    var cleanup: Task<Void, Never>?
    var id: VoiceSessionID { leg.session }
    var scope: VoiceOperationScope { leg.scope }

    init(id: VoiceSessionID, local: VoiceEndpoint, media: any VoiceMedia) {
        leg = VoiceLeg(session: id)
        dialed = local
        self.media = media
    }
}

extension VoiceService {
    func start() async throws {
        guard canStart else { throw VoiceIssue.busy }
        guard let signaling else { issue = .relayUnsupported; throw VoiceIssue.relayUnsupported }
        guard case .ready(let local) = signaling.voiceAvailability else {
            let reason: VoiceIssue = signaling.voiceAvailability == .unsupported ? .relayUnsupported : .macUnavailable
            issue = reason
            throw reason
        }
        let owner = VoicePhoneSession(id: VoiceSessionID(UUID()), local: local, media: makeMedia())
        adopt(owner)
        do {
            let profile = try await owner.scope.perform { try await self.services.store.cueProfile() }
            guard let host = profile?.activeHost else { throw VoiceIssue.cueUnavailable }
            let peer = try await owner.scope.perform { try await signaling.resolveVoicePeer(VoiceDeviceID(host)) }
            guard signaling.voiceAvailability == .ready(endpoint: local) else { throw VoiceSignalError.leaseChanged }
            owner.leg.link = .bound(local: local, peer: peer)
            phoneBinding = (owner.id, local, peer)
            let offer = try await owner.scope.perform { try await owner.media.offer() }
            try await owner.scope.perform {
                try await signaling.sendVoice(.media(signal: .offer(value: VoiceOffer(sdp: offer))), session: owner.id, to: peer)
            }
        } catch {
            guard phone === owner, !owner.scope.ended else { return }
            AppServices.log.error("Voice start failed: \(String(describing: error), privacy: .public)")
            let reason = error as? VoiceIssue ?? Self.phoneIssue(error)
            await end(reason: .mediaFailed)
            issue = reason
            throw reason
        }
    }

    func adopt(_ owner: VoicePhoneSession) {
        preview.stop()
        phone = owner
        phoneBinding = nil
        phoneEnd = nil
        session = owner.id
        issue = nil
        setProjection(nil)
        muted = false
        inputSamples = []
        outputSamples = []
        outputActive = false
        owner.media.onEvent = { [weak self, weak owner] event in
            guard let self, let owner, self.phone === owner, !owner.scope.ended else { return }
            self.mediaEvent(event, owner: owner)
        }
        owner.leg.depart = { [weak self, weak owner] reason in
            guard let self, let owner, self.phone === owner else { return }
            self.failPending { $0.session == owner.id }
            await self.end(reason: reason, notify: false)
        }
        owner.deadline = owner.scope.spawn { [weak self] in
            do { try await Task.sleep(for: VoiceTiming.connection) }
            catch { return }
            guard let self, self.phone === owner else { return }
            await self.end(reason: .timedOut)
        }
    }

    func setMuted(_ value: Bool) async throws {
        guard canMute, let owner = phone else { throw VoiceIssue.busy }
        muting = true
        defer { if phone === owner { muting = false } }
        try await owner.scope.perform { try await owner.media.setMuted(value) }
        guard phone === owner, !owner.scope.ended else { throw CancellationError() }
        muted = value
    }

    func hangUp() async { await end() }

    func end(reason: VoiceEndReason = .hungUp, notify: Bool = true) async {
        guard let owner = phone else { return }
        await beginEnd(owner, reason: reason, notify: notify).value
    }

    private func beginEnd(_ owner: VoicePhoneSession, reason: VoiceEndReason, notify: Bool = true) -> Task<Void, Never> {
        if let cleanup = owner.cleanup { return cleanup }
        let cleanup = Task { await self.finish(owner, reason: reason, notify: notify) }
        owner.cleanup = cleanup
        owner.scope.end()
        owner.media.onEvent = { _ in }
        return cleanup
    }

    private func finish(_ owner: VoicePhoneSession, reason: VoiceEndReason, notify: Bool) async {
        await owner.media.close()
        if notify, case .bound(_, let peer)? = owner.leg.link, let signaling {
            let send = VoiceOperationScope()
            defer { send.end() }
            do {
                try await send.perform(within: VoiceTiming.send) {
                    try await signaling.sendVoice(.media(signal: .hangup(reason: reason)), session: owner.id, to: peer)
                }
            } catch { AppServices.log.error("Voice hangup not sent: \(error.localizedDescription, privacy: .public)") }
        }
        guard phone === owner else { return }
        phone = nil
        muting = false
        phoneEnd = .ended(reason: reason)
        var leftover: [@MainActor () async -> Void] = []
        if notify, case .relinking(let mac, let until, _)? = owner.leg.link, let signaling {
            leftover.append { [weak self] in
                var sent = false
                await VoiceLeg.reach(mac, until: until, signaling: signaling, done: { sent }) { signaling, peer in
                    try await signaling.sendVoice(.media(signal: .hangup(reason: reason)), session: owner.id, to: peer)
                    sent = true
                    guard let self, self.session == owner.id, case .ready(let local) = signaling.voiceAvailability else { return }
                    self.phoneBinding = (owner.id, local, peer)
                }
            }
        }
        if UIApplication.shared.applicationState == .background {
            leftover.append { await self.services.prepareForBackground() }
        }
        guard !leftover.isEmpty else { return }
        Task { await BackgroundWork.run { for work in leftover { await work() } } }
    }

    func connectionClosed(local: VoiceEndpoint?, peer: VoiceEndpoint?, reason: VoiceEndReason) async {
        guard let owner = phone, !owner.scope.ended else { return }
        guard owner.leg.link != nil else {
            if local == owner.dialed, peer == nil { await end(reason: reason, notify: false) }
            return
        }
        guard owner.leg.carries(local: local, peer: peer) else { return }
        await owner.leg.closed(reason, signaling: signaling)
    }

    func rebind(_ header: VoiceSignalHeader) {
        guard let owner = phone, !owner.scope.ended, owner.leg.rebind(header) else { return }
        phoneBinding = (owner.id, header.recipient, header.sender)
        for (id, wait) in pending where wait.session == owner.id {
            pending[id] = Pending(session: wait.session, peer: header.sender, local: header.recipient, finish: wait.finish)
        }
        AppServices.log.notice("Voice signaling relinked")
    }

    func waitsForRelink(_ session: VoiceSessionID) -> Bool {
        guard let owner = phone, owner.id == session, case .relinking? = owner.leg.link else { return false }
        return true
    }

    func revokeProjection(local: VoiceEndpoint? = nil, peer: VoiceEndpoint? = nil) {
        guard local == nil || phoneBinding?.local == local, peer == nil || phoneBinding?.peer == peer else { return }
        phoneBinding = nil
    }

    func receiveSignal(_ received: VoiceReceivedSignal) async {
        if case .projection = received.payload {
            guard let binding = phoneBinding, binding.session == session, binding.session == received.header.session,
                  binding.local == received.header.recipient, binding.peer == received.header.sender else { return }
        }
        if phone == nil, case .projection(let value) = received.payload, value.session == session {
            setProjection(value)
            return
        }
        guard let owner = phone, owner.id == received.header.session,
              owner.leg.link == .bound(local: received.header.recipient, peer: received.header.sender), !owner.scope.ended else { return }
        switch received.payload {
        case .projection(let value):
            guard value.session == owner.id else { return }
            setProjection(value)
            switch value.phase {
            case .failed(let reason): await end(reason: .controlFailed, notify: false); issue = reason
            case .ended(let reason): await end(reason: reason, notify: false)
            default: break
            }
        case .media(.answer(let answer)):
            guard !owner.answered else { await end(reason: .protocolRejected); return }
            guard answer.version == VoiceSignalFormat.callVersion else { return await otherVersion(owner.id) }
            owner.answered = true
            do { try await owner.scope.perform { try await owner.media.accept(answer: answer.sdp) } }
            catch {
                guard phone === owner, !owner.scope.ended else { return }
                AppServices.log.error("Voice answer not applied: \(String(describing: error), privacy: .public)")
                await end(reason: .mediaFailed)
            }
        case .media(.hangup(let reason)): await end(reason: reason, notify: false)
        case .media(.resume(let ask)):
            guard ask else { return }
            owner.scope.spawn { [weak self] in
                do { try await self?.signaling?.sendVoice(.media(signal: .resume(ask: false)), session: owner.id, to: received.header.sender) }
                catch { AppServices.log.error("Voice resume answer not sent: \(error.localizedDescription, privacy: .public)") }
            }
        default: await end(reason: .protocolRejected)
        }
    }

    func otherVersion(_ session: VoiceSessionID) async {
        guard let owner = phone, owner.id == session else { return }
        AppServices.log.notice("Voice call \(session.rawValue, privacy: .public): the Mac speaks another signal version")
        await end(reason: .protocolRejected)
        issue = .relayUnsupported
    }

    private func mediaEvent(_ event: VoicePeer.Event, owner: VoicePhoneSession) {
        switch event {
        case .connected:
            owner.leg.connected = true
            owner.deadline?.cancel()
            owner.scope.spawn { [weak self] in
                guard let self, case .bound(_, let peer)? = owner.leg.link, let signaling = self.signaling else { return }
                do { try await signaling.sendVoice(.media(signal: .event(value: .connected)), session: owner.id, to: peer) }
                catch { if self.phone === owner { await self.end(reason: .networkFailed) } }
            }
        case .ended(let reason):
            AppServices.log.error("Voice media ended: \(reason.rawValue, privacy: .public)")
            _ = beginEnd(owner, reason: reason)
        case .sample(let side, let peak):
            if side == .input { inputSamples = Array((inputSamples + [peak]).suffix(VoicePeer.sampleCount)) }
            else { outputSamples = Array((outputSamples + [peak]).suffix(VoicePeer.sampleCount)) }
        case .level(let side, let loud, _): if side == .output { outputActive = loud }
        }
    }

    private static func phoneIssue(_ error: Error) -> VoiceIssue {
        switch error {
        case VoicePeerError.microphoneDenied: .ended(.permissionDenied)
        case VoiceSignalError.unsupported: .relayUnsupported
        case VoiceSignalError.peerUnavailable, VoiceSignalError.unavailable: .macUnavailable
        case VoiceSignalError.expired: .ended(.timedOut)
        default: .ended(.mediaFailed)
        }
    }
}
#endif
