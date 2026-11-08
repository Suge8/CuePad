#if os(iOS)
import Foundation

/// 本次手机媒体及异步操作的所有权；租约、会话身份固定，结束后不复用。
final class VoicePhoneSession {
    let id: VoiceSessionID
    let local: VoiceEndpoint
    let media: any VoiceMedia
    let scope = VoiceOperationScope()
    var peer: VoiceEndpoint?
    var connected = false
    var answered = false
    var deadline: Task<Void, Never>?

    init(id: VoiceSessionID, local: VoiceEndpoint, media: any VoiceMedia) {
        self.id = id
        self.local = local
        self.media = media
    }
}

extension VoiceService {
    func start(makeMedia: () -> any VoiceMedia = { VoicePeer(source: .microphone(device: nil), recording: nil) }) async throws {
        guard canStart else { throw VoiceIssue.busy }
        guard let signaling else { issue = .relayUnsupported; throw VoiceIssue.relayUnsupported }
        guard case .ready(let local) = signaling.voiceAvailability else {
            let reason: VoiceIssue = signaling.voiceAvailability == .unsupported ? .relayUnsupported : .macUnavailable
            issue = reason
            throw reason
        }
        let owner = VoicePhoneSession(id: VoiceSessionID(UUID()), local: local, media: makeMedia())
        phone = owner
        phoneBinding = nil
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
        owner.deadline = owner.scope.spawn { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) }
            catch { return }
            guard let self, self.phone === owner else { return }
            await self.end(reason: .timedOut)
        }
        do {
            let profile = try await owner.scope.perform { try await self.services.store.cueProfile() }
            guard let host = profile?.activeHost else { throw VoiceIssue.cueUnavailable }
            let peer = try await owner.scope.perform { try await signaling.resolveVoicePeer(VoiceDeviceID(host)) }
            guard signaling.voiceAvailability == .ready(endpoint: local) else { throw VoiceSignalError.leaseChanged }
            owner.peer = peer
            phoneBinding = (owner.id, local, peer)
            let offer = try await owner.scope.perform { try await owner.media.offer() }
            try await owner.scope.perform {
                try await signaling.sendVoice(.media(signal: .offer(value: VoiceOffer(sdp: offer))), session: owner.id, to: peer)
            }
        } catch {
            guard phone === owner, !owner.scope.ended else { return }
            let reason = error as? VoiceIssue ?? Self.phoneIssue(error)
            await end(reason: .mediaFailed)
            issue = reason
            throw reason
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

    func end(reason: VoiceEndReason = .hungUp, notify: Bool = true) async {
        guard let owner = phone, !closing else { return }
        closing = true
        owner.scope.end()
        owner.media.onEvent = { _ in }
        var failure: VoiceIssue?
        do { try await owner.media.close() }
        catch { failure = .shutdownUnconfirmed }
        if notify, let peer = owner.peer, let signaling {
            let send = VoiceOperationScope()
            defer { send.end() }
            do {
                try await send.perform(within: .seconds(2)) {
                    try await signaling.sendVoice(.media(signal: .hangup(reason: reason)), session: owner.id, to: peer)
                }
            } catch { failure = failure ?? .ended(.networkFailed) }
        }
        guard phone === owner else { return }
        phone = nil
        closing = false
        muting = false
        let prior = projection
        setProjection(.init(session: owner.id, phase: failure.map { .failed($0) } ?? .ended(reason: reason),
                            requests: prior?.requests ?? [], replies: prior?.replies ?? [], executions: prior?.executions ?? []))
        issue = failure
    }

    func connectionClosed(local: VoiceEndpoint?, peer: VoiceEndpoint?, reason: VoiceEndReason) async {
        guard let owner = phone, local == nil || owner.local == local, peer == nil || owner.peer == peer else { return }
        await end(reason: reason, notify: false)
    }

    func receiveSignal(_ received: VoiceReceivedSignal) async {
        if phone == nil, let binding = phoneBinding, binding.session == session,
           binding.session == received.header.session, binding.local == received.header.recipient, binding.peer == received.header.sender,
           case .projection(let value) = received.payload, value.session == binding.session {
            if case .failed(let reason) = value.phase { issue = reason }
            setProjection(.init(session: value.session, phase: projection?.phase ?? value.phase,
                                requests: value.requests, replies: value.replies, executions: value.executions))
            return
        }
        guard let owner = phone, owner.id == received.header.session, owner.local == received.header.recipient,
              owner.peer == received.header.sender, !owner.scope.ended else { return }
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
            owner.answered = true
            do { try await owner.scope.perform { try await owner.media.accept(answer: answer.sdp) } }
            catch { if phone === owner, !owner.scope.ended { await end(reason: .mediaFailed) } }
        case .media(.hangup(let reason)): await end(reason: reason, notify: false)
        default: await end(reason: .protocolRejected)
        }
    }

    private func mediaEvent(_ event: VoicePeer.Event, owner: VoicePhoneSession) {
        switch event {
        case .connected:
            owner.connected = true
            owner.deadline?.cancel()
            owner.scope.spawn { [weak self] in
                guard let self, let peer = owner.peer, let signaling = self.signaling else { return }
                do { try await signaling.sendVoice(.media(signal: .event(value: .connected)), session: owner.id, to: peer) }
                catch { if self.phone === owner { await self.end(reason: .networkFailed) } }
            }
        case .ended(let reason): Task { if phone === owner { await end(reason: reason) } }
        case .failed: Task { if phone === owner { await end(reason: .mediaFailed) } }
        case .sample(let side, let peak):
            if side == .input { inputSamples = Array((inputSamples + [peak]).suffix(VoicePeer.sampleCount)) }
            else { outputSamples = Array((outputSamples + [peak]).suffix(VoicePeer.sampleCount)) }
        case .level(let side, let loud, _): if side == .output { outputActive = loud }
        case .inputEnded, .device: break
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
