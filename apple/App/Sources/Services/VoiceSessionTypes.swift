import CueStore
import Foundation

/// 一次媒体连接的客户端 UUID，不是 OpenAI 的 call ID；对象关闭后不得换 ID 复用资源。
nonisolated struct VoiceSessionID: Hashable, Codable, Sendable {
    let rawValue: UUID
    init(_ rawValue: UUID) { self.rawValue = rawValue }
}

/// 已有 Viewer.device / Mac hostID 的原字符串路由值。
nonisolated struct VoiceDeviceID: Hashable, Codable, Sendable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
}

/// 本机每次连接生成并签名的随机 UUID；服务器只能回显，不能替换本机预期值。
/// 同账号成员共享密钥，彼此不按互不信任设备隔离；Relay 无密钥，不能为旧密文改写租约。
nonisolated struct VoiceEndpoint: Hashable, Codable, Sendable {
    let device: VoiceDeviceID
    let lease: UUID
}

nonisolated enum VoiceEndReason: String, Codable, Sendable {
    case hungUp, background, permissionDenied, audioInterrupted, mediaFailed, controlFailed
    case peerLeft, leaseReplaced, accountChanged, networkFailed, timedOut, protocolRejected, relayCapacity
}

/// Mac 唯一 VoiceCall 的只读投影。处理/说来自 Mac 的控制事件，不用手机音量猜测；结束不推断业务已撤销或执行已停止。
/// 正文和持久化业务状态仍从 CueMessage/PiSessionState 读取，信令不复制聊天历史。
nonisolated struct VoiceCallProjection: Equatable, Codable, Sendable {
    enum Phase: Equatable, Codable, Sendable {
        case connecting, listening, processing, speaking, closing
        case failed(VoiceIssue)
        case ended(reason: VoiceEndReason)
    }
    let session: VoiceSessionID
    let phase: Phase
    let requests: [Request]
    let replies: [Reply]
    let executions: [VoiceExecutionTarget]
    /// 控制协议的回应进度，与收音、请求写库、后台执行分开；不表示 PCM 已播放到某个位置。
    enum Response: String, Codable, Sendable { case none, awaitingAssistant, assistantTurn }
    var response: Response = .none

    struct Request: Equatable, Codable, Sendable {
        let reference: VoiceRequestReference
        let recording: Bool
        let issue: VoiceIssue?
    }
    struct Reply: Equatable, Codable, Sendable {
        /// 现有 CueMessage.id；正文与 answeredRequests 仍由 Store/CloudKit 提供。
        let message: UUID
        let readback: Readback
    }
    /// submitted 不证明已读出；挂断不自动将它改成异常。只有未完成的发送或实际错误才是 unconfirmed。
    enum Readback: String, Codable, Sendable { case awaitingOrigin, queued, sending, submitted, unconfirmed }
}

/// 可跨设备呈现的原因与动作，不转发上游错误原文、请求头、服务器 call ID 或授权。
nonisolated enum VoiceIssue: Error, Equatable, Codable, Sendable {
    case ended(VoiceEndReason)
    case codexNotInstalled, signedOut, cueUnavailable, macUnavailable, relayUnsupported, busy
    case notAllowed(status: Int)
    case server(status: Int?)
    case storageUnavailable, originalMissing, alreadyHandled, turnChanged, shutdownUnconfirmed

    enum Action: String, Codable, Sendable { case reconnect, microphoneSettings, configureOnMac, signInOnMac, installCodexOnMac, retryLater }
    var actions: [Action] {
        switch self {
        case .ended(.permissionDenied): [.microphoneSettings, .reconnect]
        case .codexNotInstalled: [.installCodexOnMac]
        case .signedOut: [.signInOnMac]
        case .cueUnavailable: [.configureOnMac]
        case .notAllowed, .relayUnsupported, .busy, .storageUnavailable, .macUnavailable: [.retryLater]
        case .originalMissing, .alreadyHandled, .turnChanged: []
        case .ended, .server, .shutdownUnconfirmed: [.reconnect]
        }
    }
}
