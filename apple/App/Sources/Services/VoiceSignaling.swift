import Foundation

/// Relay 扩展的 wire body，统一封装在 {"t":"voice","body":<本枚举的 Codable JSON>}。
/// 带关联值的 enum 使用 Swift Codable 的带名字形状，例如 {"resolve":{"request":"UUID","device":{"rawValue":"..."}}}。
/// 原 auth/ring/ping 仍走旧协议：服务器在 ready 附加 voiceVersion=1 后，新客户端才可 register；旧 ready 不附加则只保留门铃。
/// register 仍用现有房间签名密钥：签 UTF-8 registrationContext + LF，再接 VoiceRegistrationClaim 的 sortedKeys/withoutEscapingSlashes JSON。
/// 服务器验证当前 socket 的 room/challenge，登记设备并签发新租约；同设备替换必须先使旧租约失效并通知观察者。
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

    func signatureInput() throws -> Data {
        try Data((VoiceSignalFormat.registrationContext + "\n").utf8) + VoiceSignalFormat.canonicalJSON(self)
    }
}

/// 服务器只校验已认证来源、双方当前租约、大小与期限并定向转发 opaque packet；不解密、不留历史、不重试。
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
nonisolated enum VoiceSignalRejection: String, Codable, Sendable { case expired, leaseMismatch, unavailable, tooLarge, invalid }

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
}

/// 由既有 Relay 实现，不另起 socket/心跳/run/reconnect 状态机。AppServices 是唯一事件消费者；其余读服务投影。
/// 账号变化、网络失败、源退出、替换租约均终止绑定通话；重连只产生新租约，不复活旧通话或重发业务命令。
/// 此 checkpoint 只声明接口，没有使现有 Relay 假装支持通话。
@MainActor protocol VoiceSignaling: AnyObject {
    var voiceAvailability: VoiceRelayAvailability { get }
    /// 在启用 Relay 前由 AppServices 订阅，沿用该连接的有序事件，不丢失 closed/departed。
    var voiceEvents: AsyncStream<VoiceRelayEvent> { get }

    func resolveVoicePeer(_ device: VoiceDeviceID) async throws -> VoiceEndpoint
    /// 自动取本机当前租约、分配序号/期限并加密；必须检查调用时选定的目标租约仍有效。
    /// 返回只表示本机 WebSocket 提交，不能冒充远端收到或业务成功；取消/断线不重试、不排队到下一次连接。
    func sendVoice(_ payload: VoiceSignalPayload, session: VoiceSessionID, to recipient: VoiceEndpoint) async throws
}
