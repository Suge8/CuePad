import Foundation

/// Relay 扩展的 wire body，统一封装在 {"t":"voice","body":<本枚举的 Codable JSON>}。
/// 带关联值的 enum 使用 Swift Codable 的带名字形状，例如 {"resolve":{"request":"UUID","device":{"rawValue":"..."}}}。
/// 原 auth/ring/ping 仍走旧协议：服务器在 ready 附加 voiceVersion=1 后，新客户端才可 register；旧 ready 不附加则只保留门铃。
/// register 仍用现有房间签名密钥：签 UTF-8 registrationContext + LF，再接 VoiceRegistrationClaim 的 sortedKeys/withoutEscapingSlashes JSON。
/// 服务器验证当前 socket 的 room/challenge 及客户端新 lease 的签名后原样登记；同设备替换必须先使旧租约失效并通知观察者。
/// registered 必须回显 claim 的 device/lease，客户端不得采用服务器给出的其他值；本机每次连接都生成新 UUID，即使 challenge 被重放。
/// signature 是 64 字节 Ed25519 签名的标准 base64（Data 的 Codable 编码），room/challenge 沿用旧握手的 base64url。
/// 同一 socket 只登记一次；拒绝空设备 ID、超长 ID、未知版本/帧形状。被替换的旧 socket 以 replacedCloseCode 关闭。
nonisolated enum VoiceRelayRequest: Equatable, Codable, Sendable {
    case register(claim: VoiceRegistrationClaim, signature: Data)
    /// 返回当前租约，并订阅该租约离开/替换事件；没有目标立即 unavailable，不等待 MacPresence、不轮询。
    case resolve(request: UUID, device: VoiceDeviceID)
    case signal(packet: VoiceSealedSignal)
}

nonisolated struct VoiceRegistrationClaim: Equatable, Codable, Sendable {
    let version: UInt8
    let room: String
    let challenge: String
    let device: VoiceDeviceID
    let lease: UUID

    init(room: String, challenge: String, device: VoiceDeviceID) {
        version = VoiceSignalFormat.version
        self.room = room
        self.challenge = challenge
        self.device = device
        lease = UUID()
    }

    var endpoint: VoiceEndpoint { VoiceEndpoint(device: device, lease: lease) }

    func signatureInput() throws -> Data {
        try Data((VoiceSignalFormat.registrationContext + "\n").utf8) + VoiceSignalFormat.canonicalJSON(self)
    }
}

/// 服务器只校验已认证来源、双方当前租约与大小并定向转发 opaque packet；不解密、不留历史、不重试。
/// 每次成功投递都使双方观察对端租约；源退出/被替换必须发 departed，不能只关闭源 socket 后让目的端继续通话。
/// signal.header.sender 必须等于该 socket 的已登记 endpoint；recipient 必须仍在同房间且租约匹配，绝不广播或改投新租约。
nonisolated enum VoiceRelayResponse: Equatable, Codable, Sendable {
    case registered(endpoint: VoiceEndpoint)
    case resolved(request: UUID, endpoint: VoiceEndpoint)
    case unavailable(request: UUID, device: VoiceDeviceID)
    case departed(endpoint: VoiceEndpoint, reason: VoicePeerDeparture)
    case signal(packet: VoiceSealedSignal)
    /// 定向帧无法交到当前目标；只回关联头，不回正文，也不声称远端已收到。
    case rejected(header: VoiceSignalHeader, reason: VoiceSignalRejection)
}

nonisolated enum VoicePeerDeparture: String, Codable, Sendable { case disconnected, replaced }
nonisolated enum VoiceSignalRejection: String, Codable, Sendable { case leaseMismatch, unavailable, tooLarge, invalid }

nonisolated enum VoiceRelayAvailability: Equatable, Sendable {
    case unavailable
    case unsupported
    case ready(endpoint: VoiceEndpoint)
}

nonisolated enum VoiceRelayEvent: Equatable, Sendable {
    case availability(VoiceRelayAvailability)
    /// 已有 Relay 网络失败、换账号、暂停或替换连接时发出，必须携带被关闭的旧租约；迟到通知不能关新连接。
    case localClosed(endpoint: VoiceEndpoint, reason: VoiceEndReason)
    case peerClosed(endpoint: VoiceEndpoint, reason: VoicePeerDeparture)
    case received(VoiceReceivedSignal)
    case rejected(header: VoiceSignalHeader, reason: VoiceSignalRejection)
}

nonisolated enum VoiceSignalError: Error {
    case unavailable, unsupported, peerUnavailable, leaseChanged, expired, tooLarge, invalid
    case rejected(VoiceSignalRejection)
}

/// 一通电话在中转上的绑定，是通话 owner（手机 `VoicePhoneSession`、Mac `VoiceRemoteMedia`）唯一的链路状态。
/// 中转只承担协调（挂断、业务投影、命令），媒体直连 OpenAI、Mac 的控制连接也不经它：信令断了通话照常，
/// 已接通的转入 relinking 等对端以新租约回来，"已离开"只在 until 到了还没回来时成立，按 reason（断开时的原因）结束。
/// 身份是同一设备 + 同一通话（header.session）：这样的一帧从新租约到达即换绑，序号随新租约对从 1 数，旧租约已退役、残帧不认。
nonisolated enum VoiceLink: Equatable, Sendable {
    case bound(local: VoiceEndpoint, peer: VoiceEndpoint)
    case relinking(peer: VoiceDeviceID, until: ContinuousClock.Instant, reason: VoiceEndReason)

    var peerDevice: VoiceDeviceID {
        switch self {
        case .bound(_, let peer): peer.device
        case .relinking(let peer, _, _): peer
        }
    }

    var isBound: Bool { if case .bound = self { true } else { false } }

    /// 换账号、协议被拒、中转满员不是一时断开，等也回不来。
    static func canRelink(after reason: VoiceEndReason) -> Bool { [.networkFailed, .peerLeft, .leaseReplaced].contains(reason) }
}

/// 由既有 Relay 实现，不另起 socket/心跳/run/reconnect 状态机。AppServices 是唯一事件消费者；其余读服务投影。
/// 账号变化、网络失败、源退出、替换租约都关掉旧租约上的一切等待；已接通的通话按 `VoiceLink` 等对端回来，未确认的业务命令不重发。
@MainActor protocol VoiceSignaling: AnyObject {
    var voiceAvailability: VoiceRelayAvailability { get }
    /// 在启用 Relay 前由 AppServices 订阅，沿用该连接的有序事件，不丢失 closed/departed。
    var voiceEvents: AsyncStream<VoiceRelayEvent> { get }

    func resolveVoicePeer(_ device: VoiceDeviceID) async throws -> VoiceEndpoint
    /// 自动取本机当前租约、分配序号/期限并加密；必须检查调用时选定的目标租约仍有效。
    /// 返回只表示本机 WebSocket 提交，不能冒充远端收到或业务成功；取消/断线不重试、不排队到下一次连接。
    func sendVoice(_ payload: VoiceSignalPayload, session: VoiceSessionID, to recipient: VoiceEndpoint) async throws
}
