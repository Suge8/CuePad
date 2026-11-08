import CryptoKit
import Foundation

/// 一条既有 Relay 连接的加密与防重放记录，不拥有 socket、心跳或重连任务。
/// 本机 lease 只由这里创建，registered 不提供身份来源；对端退役及最高序号保留到本机连接终止。
/// 同账号成员共享密钥，互相可信；不信任 Relay 的 challenge、路由、登记回执和租约退出通知。
final class VoiceSignalConnection {
    let claim: VoiceRegistrationClaim
    private let key: SymmetricKey
    private enum Registration { case pending, accepted, ended }
    private var registration = Registration.pending
    private struct Peer {
        let endpoint: VoiceEndpoint
        var received: UInt32 = 0
        var sent: UInt32 = 0
    }
    private var peers: [VoiceDeviceID: Peer] = [:]
    private var retired: Set<VoiceEndpoint> = []
    /// 恶意中转不能靠无尽 departed 耗尽内存；达到上限结束本机租约，不能清空记录后沿用它。
    private static let maximumPeers = 1024
    private static let gcmOverhead = 28

    init(room: String, challenge: String, device: VoiceDeviceID, key: SymmetricKey) {
        claim = VoiceRegistrationClaim(room: room, challenge: challenge, device: device)
        self.key = key
    }

    func acceptRegistration(_ endpoint: VoiceEndpoint) throws {
        guard registration == .pending, endpoint == claim.endpoint else {
            end()
            throw VoiceSignalError.leaseChanged
        }
        registration = .accepted
    }

    func end() { registration = .ended }

    func bind(_ endpoint: VoiceEndpoint) throws {
        try requireAccepted()
        guard endpoint != claim.endpoint, !retired.contains(endpoint) else { throw VoiceSignalError.leaseChanged }
        if let previous = peers[endpoint.device] {
            guard previous.endpoint != endpoint else { return }
            try retire(previous.endpoint)
        }
        try reserve(endpoint)
        peers[endpoint.device] = Peer(endpoint: endpoint)
    }

    func retire(_ endpoint: VoiceEndpoint) throws {
        try requireAccepted()
        try reserve(endpoint)
        retired.insert(endpoint)
        if peers[endpoint.device]?.endpoint == endpoint { peers.removeValue(forKey: endpoint.device) }
    }

    func seal(_ payload: VoiceSignalPayload, session: VoiceSessionID, to recipient: VoiceEndpoint, now: Int64) throws -> VoiceSealedSignal {
        try requireAccepted()
        guard var peer = peers[recipient.device], peer.endpoint == recipient, peer.sent < .max else { throw VoiceSignalError.leaseChanged }
        let data = try VoiceSignalFormat.canonicalJSON(payload)
        guard data.count <= VoiceSignalFormat.maximumPlaintextBytes else { throw VoiceSignalError.tooLarge }
        let header = VoiceSignalHeader(version: VoiceSignalFormat.version, sender: claim.endpoint, recipient: recipient,
                                       session: session, sequence: peer.sent + 1, expiresAtMilliseconds: now + VoiceSignalFormat.lifetimeMilliseconds)
        let sealed = try AES.GCM.seal(data, using: key, authenticating: header.authenticationData())
        guard let combined = sealed.combined else { throw VoiceSignalError.invalid }
        peer.sent = header.sequence
        peers[recipient.device] = peer
        return VoiceSealedSignal(header: header, sealed: combined)
    }

    func open(_ packet: VoiceSealedSignal, now: Int64) throws -> VoiceReceivedSignal {
        try requireAccepted()
        let header = packet.header
        guard header.version == VoiceSignalFormat.version, header.recipient == claim.endpoint,
              !retired.contains(header.sender), var peer = peers[header.sender.device], peer.endpoint == header.sender
        else { throw VoiceSignalError.leaseChanged }
        guard header.expiresAtMilliseconds > now, header.expiresAtMilliseconds <= now + VoiceSignalFormat.lifetimeMilliseconds
        else { throw VoiceSignalError.expired }
        guard header.sequence > peer.received else { throw VoiceSignalError.invalid }
        guard packet.sealed.count <= VoiceSignalFormat.maximumPlaintextBytes + Self.gcmOverhead else { throw VoiceSignalError.tooLarge }
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: packet.sealed), using: key, authenticating: header.authenticationData())
        let payload = try JSONDecoder().decode(VoiceSignalPayload.self, from: plaintext)
        peer.received = header.sequence
        peers[header.sender.device] = peer
        return VoiceReceivedSignal(header: header, payload: payload)
    }

    private func requireAccepted() throws {
        guard registration == .accepted else { throw VoiceSignalError.unavailable }
    }

    private func reserve(_ endpoint: VoiceEndpoint) throws {
        guard !retired.contains(endpoint), peers[endpoint.device]?.endpoint != endpoint else { return }
        guard peers.count + retired.count < Self.maximumPeers else {
            end()
            throw VoiceSignalError.tooLarge
        }
    }
}
