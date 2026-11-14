import CueStore
import Foundation

/// 已落库时只引用原 CueMessage UUID；未落库时引用那一通的 VoiceRecord.Request.rowID。
/// unrecorded 不产生新业务库，Mac 丢失原对象就拒绝恢复，不能从客户端补造正文或请求。
nonisolated enum VoiceRequestReference: Hashable, Codable, Sendable {
    case recorded(message: UUID)
    case unrecorded(session: VoiceSessionID, request: UUID)
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
        /// Mac 从已核实的 Cue 请求 → 投送 → 实际会话回合派生的那一轮；执行前同事务重验，Agent 接收端仍核对原 delivery，
        /// 任何一项已变就拒绝，不能按 sessionID 改停后来的工作。
        case stop(target: TurnTarget)
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
        /// 只表示进入朗读队列；没有播放成功的承诺。
        case readbackQueued(message: UUID)
        case rejected(reason: Rejection)
    }

    enum Rejection: String, Codable, Sendable {
        case originalMissing, alreadyHandled, unconfirmed, sourceMismatch, turnChanged, unavailable, failed
    }

    let command: VoiceCommand.ID
    let outcome: Outcome
}
