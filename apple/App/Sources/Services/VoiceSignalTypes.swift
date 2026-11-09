import Foundation

/// 明文只在两端内存中存在，服务器只接触路由头与密文。业务命令独立于媒体生命周期，不能因原媒体已结束而丢掉合法恢复。
nonisolated enum VoiceSignalPayload: Equatable, Codable, Sendable {
    case media(signal: VoiceMediaSignal)
    case command(command: VoiceCommand)
    case commandResult(result: VoiceCommandResult)
    case projection(value: VoiceCallProjection)
    case pageQuery(query: VoicePageQuery)
    case pageResult(result: VoicePageResult)
}

/// 拒绝只能结算原发送的归属；结果帧与请求帧分开，回执发送失败不能误伤同 UUID 的本地请求。
nonisolated enum VoiceSignalPurpose: Equatable, Codable, Sendable {
    case media
    case command(id: VoiceCommand.ID)
    case commandResult(id: VoiceCommand.ID)
    case pageQuery(id: VoiceCommand.ID)
    case pageResult(id: VoiceCommand.ID)
}

extension VoiceSignalPayload {
    var purpose: VoiceSignalPurpose {
        switch self {
        case .media, .projection: .media
        case .command(let command): .command(id: command.id)
        case .commandResult(let result): .commandResult(id: result.command)
        case .pageQuery(let query): .pageQuery(id: query.id)
        case .pageResult(let result): .pageResult(id: result.query)
        }
    }
}

nonisolated enum VoiceMediaSignal: Equatable, Codable, Sendable {
    case offer(value: VoiceOffer)
    case answer(value: VoiceAnswer)
    case event(value: VoiceMediaEvent)
    case hangup(reason: VoiceEndReason)
    /// 手机发：同一通（header.session）它以 header.sender 这个租约回来了（`VoiceLink`、`VoiceSignalFormat.relinkGrace`）。
    /// 手机等 Mac 时主动发、收到 Mac 新租约的帧后也回一个；Mac 收到就回当前投影。双方各收到对方新租约的一帧才算接回。
    case resume
}

/// 每帧的 AEAD 认证头。session 对媒体指当前通话，对业务命令指原通话来源，不限制命令必须在原通话存活时执行。
/// sequence 由唯一 Relay 发送者按双方租约对从 1 单调分配，跨通话和命令共用，不能按 session 重置；耗尽前换连接。
/// 序号与防重放记在本机这一条中转连接上（`VoiceSignalConnection`）：通话接到新租约后从 1 重新数，旧租约的帧因收件租约不符、发件租约已退役一律不认。
/// 期限使用发端时钟的 Unix 毫秒，只由收端判定（容差见 `clockSkewMilliseconds`），中转不判；不续期、不排队。
nonisolated struct VoiceSignalHeader: Equatable, Codable, Sendable {
    let version: UInt8
    let sender: VoiceEndpoint
    let recipient: VoiceEndpoint
    let session: VoiceSessionID
    let sequence: UInt32
    let expiresAtMilliseconds: Int64
    let purpose: VoiceSignalPurpose

    func authenticationData() throws -> Data { try VoiceSignalFormat.canonicalJSON(self) }
}

/// sealed 为 AES.GCM combined（12 字节 nonce + ciphertext + 16 字节 tag），Codable 按 base64 编码。
/// AAD 是 header 的 JSONEncoder sortedKeys + withoutEscapingSlashes 编码；无 Date/浮点数，自定义编码不得另造字段。
/// 接收必须先检查 wire 大小/版本/当前双方租约，再验 AEAD、期限及单调序号，最后解码有界 payload；失败绝不能先推进最高序号。
nonisolated struct VoiceSealedSignal: Equatable, Codable, Sendable {
    let header: VoiceSignalHeader
    let sealed: Data
}

/// 只能由原生 Relay 在完成认证、AEAD、期限、序号和租约检查后发给 AppServices；此类型不携带 bearer/account header/server call ID。
nonisolated struct VoiceReceivedSignal: Equatable, Sendable {
    let header: VoiceSignalHeader
    let payload: VoiceSignalPayload
}

/// 双方实现共用的协议常量；这里没有加解密或运输的假实现。
nonisolated enum VoiceSignalFormat {
    static let version: UInt8 = 1
    static let maximumWireBytes = 64 * 1024
    static let maximumPlaintextBytes = 32 * 1024
    static let maximumDeviceIDBytes = 128
    static let replacedCloseCode = 4409
    static let lifetimeMilliseconds: Int64 = 30_000
    /// 期限由发端时钟写、收端时钟查，两台设备的时钟并不一致；零容差时发端快几十毫秒就整帧被拒。
    /// 取 JWT 校验常用的 60 秒（RFC 7519 §4.1.4 允许"几分钟以内"的余量），收端在两侧都放宽这么多。
    static let clockSkewMilliseconds: Int64 = 60_000
    /// 通话中信令断了（本机中转断、对端租约离开、发到对端被拒）等多久对端以新租约回来（`VoiceMediaSignal.resume`）。
    /// 断的只是协调：媒体直连 OpenAI、Mac 的控制连接都不经中转，这段时间通话照常；中转自己 1 秒起重连（`Relay.retry`），网络回来即连。
    /// 到期没回来才算离开，按断开时的原因结束；两端同一个值。
    static let relinkGrace: Duration = .seconds(15)
    /// 从现有 RelaySecret 经 HKDF-SHA256（空 salt、此 UTF-8 info、32 字节输出）派生 AES-256-GCM 密钥。
    static let keyContext = "cuepad-voice-signal-v1"
    static let registrationContext = "cuepad-relay-voice-v1"

    static func canonicalJSON<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
