import Foundation

/// 一次媒体连接的客户端 UUID，不是 OpenAI 的 call ID。对象关闭后不得换 ID 复用资源。
nonisolated struct VoiceSessionID: Hashable, Codable, Sendable {
    let rawValue: UUID
    init(_ rawValue: UUID) { self.rawValue = rawValue }
}

/// 已有 Viewer.device / Mac hostID 的路由值；同账号成员可证明持有房间密钥，不能证明独立物理设备身份。
nonisolated struct VoiceDeviceID: Hashable, Codable, Sendable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
}

/// Relay 在当前已认证 socket 上发的随机租约；重连、替换和账号变化必须换值，不能由客户端恢复旧值。
nonisolated struct VoiceEndpoint: Hashable, Codable, Sendable {
    let device: VoiceDeviceID
    let lease: UUID
}

nonisolated enum VoiceEndReason: String, Codable, Sendable {
    case hungUp, background, permissionDenied, audioInterrupted, mediaFailed, controlFailed
    case peerLeft, leaseReplaced, accountChanged, networkFailed, timedOut, protocolRejected
}

/// 这是 Mac 唯一 VoiceCall 的只读投影，不是手机可推进的业务状态机，不持久化第二份请求或结果。
/// AppServices 持有服务和投影；Workspace 只发动作。断线不推断任何 Cue 请求已撤销或执行已停止。
nonisolated struct VoiceCallProjection: Equatable, Codable, Sendable {
    enum Phase: Equatable, Codable, Sendable {
        case connecting, active
        case ended(reason: VoiceEndReason)
    }

    let session: VoiceSessionID
    let phase: Phase
    let requests: [VoiceRequestReference]
    let replies: [Reply]
    let executions: [VoiceExecutionTarget]

    struct Reply: Equatable, Codable, Sendable {
        /// 现有 CueMessage.id；正文与 answeredRequests 仍由 Store/CloudKit 提供。
        let message: UUID
        let readback: Readback
    }

    /// 没有逐回复播放确认；submitted/contextAccepted 都不证明已读出，挂断不自动将它们改成异常。
    enum Readback: String, Codable, Sendable {
        case notRequested, submitted, contextAccepted
    }
}
