#if os(iOS)
import Foundation
import Observation
import UIKit

/// 本次手机媒体及异步操作的所有权；会话身份固定，结束后不复用。拨号时的租约是 `dialed`，解析到 Mac 后链路只看 `link`。
@Observable final class VoicePhoneSession {
    let id: VoiceSessionID
    let dialed: VoiceEndpoint
    let media: any VoiceMedia
    let scope = VoiceOperationScope()
    var link: VoiceLink?
    var connected = false
    var answered = false
    @ObservationIgnored var deadline: Task<Void, Never>?
    var cleanup: Task<Void, Never>?

    init(id: VoiceSessionID, local: VoiceEndpoint, media: any VoiceMedia) {
        self.id = id
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
            owner.link = .bound(local: local, peer: peer)
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
    /// 结束原因就是触发结束的那个：挂断没送到不改它（Mac 那边由中转的离开事件或投影送不到收尾）。
    /// 正在等 Mac 回来时本机照样当场结束，挂断留到中转连回来再送（至多到宽限期满），Mac 收到才按真实原因结束而不是等到"对方离开"。
    private func finish(_ owner: VoicePhoneSession, reason: VoiceEndReason, notify: Bool) async {
        await owner.media.close()
        if notify, case .bound(_, let peer) = owner.link, let signaling {
            let send = VoiceOperationScope()
            defer { send.end() }
            do {
                try await send.perform(within: .seconds(2)) {
                    try await signaling.sendVoice(.media(signal: .hangup(reason: reason)), session: owner.id, to: peer)
                }
            } catch { AppServices.log.error("Voice hangup not sent: \(error.localizedDescription, privacy: .public)") }
        }
        guard phone === owner else { return }
        phone = nil
        muting = false
        phoneEnd = .ended(reason: reason)
        var leftover: [@MainActor () async -> Void] = []
        if notify, case .relinking(let mac, let until, _) = owner.link {
            leftover.append { [weak self] in
                var sent = false
                await self?.reach(mac, until: until, done: { sent }) { signaling, peer in
                    try await signaling.sendVoice(.media(signal: .hangup(reason: reason)), session: owner.id, to: peer)
                    sent = true
                    guard let self, self.session == owner.id, case .ready(let local) = signaling.voiceAvailability else { return }
                    self.phoneBinding = (owner.id, local, peer)
                }
            }
        }
        // 在后台结束的：补上进后台时为通话留着的那段收尾（断开中转等）
        if UIApplication.shared.applicationState == .background {
            leftover.append { await self.services.prepareForBackground() }
        }
        guard !leftover.isEmpty else { return }
        Task { await BackgroundWork.run { for work in leftover { await work() } } }
    }

    func connectionClosed(local: VoiceEndpoint?, peer: VoiceEndpoint?, reason: VoiceEndReason) async {
        guard let owner = phone, !owner.scope.ended else { return }
        switch owner.link {
        case nil:
            guard local == owner.dialed, peer == nil else { return }
        case .bound(let bound, let mac)?:
            guard local == nil || bound == local, peer == nil || mac == peer else { return }
            if owner.connected, VoiceLink.canRelink(after: reason) { return relink(owner, mac: mac.device, reason: reason) }
        case .relinking?: return
        }
        await end(reason: reason, notify: false)
    }

    /// 宽限期满、媒体断开、用户挂断谁先到按谁结束：后两者走 `beginEnd`，结束 owner.scope 也就停了这里的等待。
    private func relink(_ owner: VoicePhoneSession, mac: VoiceDeviceID, reason: VoiceEndReason) {
        let until = ContinuousClock.now + VoiceSignalFormat.relinkGrace
        owner.link = .relinking(peer: mac, until: until, reason: reason)
        AppServices.log.notice("Voice signaling lost (\(reason.rawValue, privacy: .public)), waiting for the Mac")
        owner.scope.spawn { [weak self] in
            await self?.reach(mac, until: until, done: { owner.link?.isBound == true }) { signaling, peer in
                try await signaling.sendVoice(.media(signal: .resume), session: owner.id, to: peer)
            }
            guard let self, self.phone === owner, owner.link?.isBound == false, !Task.isCancelled else { return }
            await self.end(reason: reason, notify: false)
        }
    }

    /// 同一 Mac、同一通话从新租约来的一帧：换绑并回一个 resume，Mac 收到才知道手机的新租约（`VoiceMediaSignal.resume`）。
    private func rebind(_ owner: VoicePhoneSession, to header: VoiceSignalHeader) {
        guard let link = owner.link, header.session == owner.id, header.sender.device == link.peerDevice,
              link != .bound(local: header.recipient, peer: header.sender) else { return }
        owner.link = .bound(local: header.recipient, peer: header.sender)
        phoneBinding = (owner.id, header.recipient, header.sender)
        AppServices.log.notice("Voice signaling relinked")
        owner.scope.spawn { [weak self] in
            do { try await self?.signaling?.sendVoice(.media(signal: .resume), session: owner.id, to: header.sender) }
            catch { AppServices.log.error("Voice resume not sent: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func receiveSignal(_ received: VoiceReceivedSignal) async {
        if let owner = phone, !owner.scope.ended { rebind(owner, to: received.header) }
        if case .projection = received.payload {
            guard let binding = phoneBinding, binding.session == session, binding.session == received.header.session,
                  binding.local == received.header.recipient, binding.peer == received.header.sender else { return }
        }
        // 本机已结束：Mac 的投影只更新业务，结束原因以本机先落定的为准（Mac 那时的投影是它收到挂断后的回声）
        if phone == nil, case .projection(let value) = received.payload, value.session == session {
            setProjection(value)
            return
        }
        guard let owner = phone, owner.id == received.header.session,
              owner.link == .bound(local: received.header.recipient, peer: received.header.sender), !owner.scope.ended else { return }
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
        case .media(.resume): break
        default: await end(reason: .protocolRejected)
        }
    }

    private func mediaEvent(_ event: VoicePeer.Event, owner: VoicePhoneSession) {
        switch event {
        case .connected:
            owner.connected = true
            owner.deadline?.cancel()
            owner.scope.spawn { [weak self] in
                guard let self, case .bound(_, let peer) = owner.link, let signaling = self.signaling else { return }
                do { try await signaling.sendVoice(.media(signal: .event(value: .connected)), session: owner.id, to: peer) }
                catch { if self.phone === owner { await self.end(reason: .networkFailed) } }
            }
        case .ended(let reason): _ = beginEnd(owner, reason: reason)
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
