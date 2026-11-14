import Foundation
import Observation

/// 两端共用的时限：连接（凭证、建连到可听，手机是到媒体接通）、单帧信令发送、信令断开后等对端回来。
nonisolated enum VoiceTiming {
    static let connection: Duration = .seconds(30)
    static let send: Duration = .seconds(2)
    /// 断的只是协调：媒体直连 OpenAI、Mac 的控制连接都不经中转，这段时间通话照常；中转自己 1 秒起重连（`Relay.retry`），网络回来即连。
    /// 到期没回来才算离开，按断开时的原因结束；两端同一个值。
    static let relinkGrace: Duration = .seconds(15)
}

/// 经中转的那一路，两端同一份：手机这一通（`VoicePhoneSession`）与 Mac 上手机打进来的那一路（`VoiceRemoteMedia`）各持一个。
/// 媒体接通后信令一时断开（`VoiceLink.canRelink`）就等对端以新租约回来（`VoiceMediaSignal.resume`），对端的任何一帧都算回来（`rebind`）；
/// 宽限期满、不能等的断开都按原因离开（`depart`）。这一路的异步操作都在 `scope` 里，离开或挂断时一起停。
@Observable final class VoiceLeg {
    let session: VoiceSessionID
    /// 解析到对端前为 nil（手机拨号时）
    var link: VoiceLink?
    /// 媒体已接通：之前的信令断开直接离开，之后的等对端回来
    var connected = false
    @ObservationIgnored let scope = VoiceOperationScope()
    /// 离开时怎么办：手机结束这一通（不再通知 Mac），Mac 让这一路的媒体带原因结束
    @ObservationIgnored var depart: (VoiceEndReason) async -> Void = { _ in }

    init(session: VoiceSessionID, link: VoiceLink? = nil) {
        self.session = session
        self.link = link
    }

    /// 中转报的这次断开落在这一路当前的租约上
    func carries(local: VoiceEndpoint?, peer: VoiceEndpoint?) -> Bool {
        guard case .bound(let bound, let other)? = link else { return false }
        return (local == nil || bound == local) && (peer == nil || other == peer)
    }

    /// 这一路断了：能等就等对端回来，否则按原因离开。canWait 是平台另加的条件（Mac 那通已结束就不等）。
    func closed(_ reason: VoiceEndReason, signaling: (any VoiceSignaling)?, canWait: Bool = true) async {
        guard case .bound(_, let peer)? = link else { return }
        if connected, canWait, VoiceLink.canRelink(after: reason), let signaling { return relink(peer.device, reason: reason, signaling: signaling) }
        await depart(reason)
    }

    /// 同一对端设备从新租约来的一帧（等着时同一租约的也算）：换到这对租约。换了返回 true。
    func rebind(_ header: VoiceSignalHeader) -> Bool {
        guard header.session == session, let link, header.sender.device == link.peerDevice else { return false }
        let pair = VoiceLink.bound(local: header.recipient, peer: header.sender)
        guard link != pair else { return false }
        self.link = pair
        return true
    }

    /// 本机的中转断了时对端未必察觉，所以这边也每秒向对端的当前租约问一次。
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

    /// 每秒试一次，直到 `done()` 或 until：本机中转在线就解析对端设备的当前租约，把这一帧发过去。
    /// 对端还没连回来时解析、发送都会失败，这是等待的常态；结果只看对端有没有以新租约回帧（`done`）和期满。
    /// 每次尝试至多用到 until：中转连着却迟迟不回解析（它自己的时限也是 15 秒）时，不能把通话拖过截止点。
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
