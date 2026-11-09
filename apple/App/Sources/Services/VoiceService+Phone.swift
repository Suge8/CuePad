#if os(iOS)
import Foundation
import Observation

/// 本次手机媒体及异步操作的所有权；租约、会话身份固定，结束后不复用。
@Observable final class VoicePhoneSession {
    let id: VoiceSessionID
    let local: VoiceEndpoint
    let media: any VoiceMedia
    let scope = VoiceOperationScope()
    var peer: VoiceEndpoint?
    var connected = false
    var answered = false
    @ObservationIgnored var deadline: Task<Void, Never>?
    var cleanup: Task<Void, Never>?

    init(id: VoiceSessionID, local: VoiceEndpoint, media: any VoiceMedia) {
        self.id = id
        self.local = local
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

    /// 不属于 owner.scope：结束可能正由该作用域的期限或发送失败触发，取消输入不能取消资源回收与挂断通知。
    private func finish(_ owner: VoicePhoneSession, reason: VoiceEndReason, notify: Bool) async {
        let closing = VoiceOperationScope()
        defer { closing.end() }
        var failure: VoiceIssue?
        do { try await closing.perform(within: .seconds(2)) { try await owner.media.close() } }
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
        muting = false
        let phase: VoiceCallProjection.Phase = failure.map { .failed($0) } ?? .ended(reason: reason)
        phoneEnd = phase
        issue = failure
    }

    func connectionClosed(local: VoiceEndpoint?, peer: VoiceEndpoint?, reason: VoiceEndReason) async {
        guard let owner = phone, local == nil || owner.local == local, peer == nil || owner.peer == peer else { return }
        await end(reason: reason, notify: false)
    }

    func receiveSignal(_ received: VoiceReceivedSignal) async {
        if case .projection = received.payload {
            guard let binding = phoneBinding, binding.session == session, binding.session == received.header.session,
                  binding.local == received.header.recipient, binding.peer == received.header.sender else { return }
        }
        if phone == nil, case .projection(let value) = received.payload, value.session == session {
            if case .failed(let reason) = value.phase { issue = reason }
            setProjection(value)
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
        case .ended(let reason): _ = beginEnd(owner, reason: reason)
        case .failed: _ = beginEnd(owner, reason: .mediaFailed)
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
