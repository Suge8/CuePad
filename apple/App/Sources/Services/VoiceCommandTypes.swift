import Foundation

/// 已落库时只引用原 CueMessage UUID；未落库时引用 Mac 当前保留的 VoiceCall.Request.rowID。
/// unrecorded 不产生新业务库，Mac 丢失原对象就拒绝恢复，不能从客户端补造正文或请求。
nonisolated enum VoiceRequestReference: Hashable, Codable, Sendable {
    case recorded(message: UUID)
    case unrecorded(session: VoiceSessionID, request: UUID)
}

/// Mac 从已核实的 Cue 请求 → 投送 → 实际会话回合派生给手机；只是操作前提，不是客户端授予的停止权限。
/// 执行前同事务重验全部字段，Agent 接收端仍核对原 delivery；任何一项已变就拒绝，不能按 sessionID 改停后来的工作。
nonisolated struct VoiceExecutionTarget: Hashable, Codable, Sendable {
    let request: UUID
    let delivery: UUID
    let host: VoiceDeviceID
    let agentSession: String
    let boot: String
    /// 既有 PiSessionState.turnStartedAt 的 Unix 毫秒；没有可核实回合时不能构造停止目标。
    let turnStartedAtMilliseconds: Int64
}

/// 用户的每次新动作各有 command ID；同一动作的重复包不能重复执行。断线不自动重发命令。
/// 恢复可以发生在媒体已结束之后：认证仍须当前双方租约，业务授权按原请求重读 Store，不能套用“当前媒体 call”过滤器。
nonisolated struct VoiceCommand: Equatable, Codable, Sendable {
    struct ID: Hashable, Codable, Sendable {
        let rawValue: UUID
        init(_ rawValue: UUID) { self.rawValue = rawValue }
    }

    enum Action: Equatable, Codable, Sendable {
        case recover(request: VoiceRequestReference)
        case repeatReply(message: UUID)
        case stop(target: VoiceExecutionTarget)
    }

    let id: ID
    let action: Action
}

/// 命令回复与媒体事件分开路由。只回原记录身份，实际结果依旧由已同步记录证明。
nonisolated struct VoiceCommandResult: Equatable, Codable, Sendable {
    enum Outcome: Equatable, Codable, Sendable {
        /// 现有发送/恢复入口实际写下的 CueMessage，不表示 Cue 已完成工作。
        case recorded(message: UUID)
        /// 现有 stopTurn 投送已入库，不表示执行回合已停止。
        case stopRequested(delivery: UUID)
        /// 只表示提交朗读；没有播放成功的承诺。
        case readbackSubmitted(message: UUID)
        case rejected(reason: Rejection)
    }

    enum Rejection: String, Codable, Sendable {
        case originalMissing, alreadyHandled, sourceMismatch, turnChanged, unavailable, failed
    }

    let command: VoiceCommand.ID
    let outcome: Outcome
}
