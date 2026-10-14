import CueStore
import CueSync
import Foundation

/// 你说出去的一句话此刻到哪了：对 Cue 说的（你的 `CueMessage`）与发给会话的（说话、作答、命令的投送请求）同一条规则，
/// 只由记录与此刻推出、不另存。会话页与 Cue 页的气泡（`SpeechBubble`）、提示词（`PromptDelivery`）、Cue 在不在（`CuePresence`）都读这里。
/// - 发送中：记录在，接收方还没回执。
/// - 已送达：会话请求成功；Cue 消息有 `deliveredAt`。
/// - 没能送达：会话请求失败（原因读 `DeliveryRequest.failure`）；或过了 `receiptLimit` 还没回执——Cue 消息没有 `deliveredAt`，
///   会话请求还没被 Mac 领取（领取了在执行的不算超时，如唤醒已结束的会话）。超时的原因只有两种：本机同步不通，或 Mac 没有回应。
///   超时后记录仍在，回执来了就是已送达；到点翻状态由界面的睡眠任务刷新"此刻"（`deadline`），不轮询。
nonisolated enum Speech {
    enum Trip: Equatable, Sendable {
        case sending
        case delivered
        case failed(Failure)
    }

    enum Failure: Equatable, Sendable {
        /// 接收方说没送到（`DeliveryRequest.failure`）
        case reported(String)
        /// 过了时限没回执，本机同步不通：话还没离开这台设备，或回执回不来
        case offline(SyncStatus)
        /// 过了时限没回执，同步是通的：接收方那台 Mac 没有回应（睡着了、没开 CuePad）
        case noReply
    }

    /// 等回执的时限（会话与 Cue 共用）。一条话正常的往返：发出方立即上传（多数 1 秒内，偶尔约 10 秒，issue #2）、Mac 主动拉取
    /// （每 2 秒）、交给 Agent 或 Cue（0.2 秒内）、回执立即上传、发出方主动拉取（每 2 秒），几秒就回来；实测最慢的约 21 秒（2026-10-14
    /// 手机对 Cue 说的话，当时值班的 Mac 没在拉）。取 60 秒：是最慢实测的约三倍，活着的 Mac 慢一点也不会被说成没有回应；
    /// 又只是手机为在等的话主动拉取时长（`SyncPoller.Cadence.phone`，2 分钟）的一半——报了没能送达之后手机还接着拉一分钟，
    /// 晚到的回执照样拉回来、气泡自己变成已送达。与连接测试的等待（`AppServices.ping`）一样长。
    static let receiptLimit: TimeInterval = 60

    /// 对 Cue 说的一句：`said` 是写下的时刻，`delivered` 是交给 Cue 的时刻。`relay` 是到接收方那台 Mac 要经过的同步（本机就是接收方为 nil）。
    static func trip(said: Date, delivered: Date?, now: Date, relay: SyncStatus?) -> Trip {
        delivered != nil ? .delivered : waiting(since: said, now: now, relay: relay)
    }

    static func trip(_ request: DeliveryRequest, now: Date, relay: SyncStatus?) -> Trip {
        switch request.status.known {
        case .pending: waiting(since: request.createdAt, now: now, relay: relay)
        case .executing: .sending
        case .succeeded: .delivered
        case .failed, nil: .failed(.reported(request.failure ?? DeliveryRequest.unexplainedFailure))
        }
    }

    /// 还在等回执的话到这一刻就算超时；已有回执（或已被领取）为 nil。
    static func deadline(said: Date, delivered: Date?) -> Date? {
        delivered == nil ? said.addingTimeInterval(receiptLimit) : nil
    }

    static func deadline(_ request: DeliveryRequest) -> Date? {
        request.status == .known(.pending) ? request.createdAt.addingTimeInterval(receiptLimit) : nil
    }

    private static func waiting(since said: Date, now: Date, relay: SyncStatus?) -> Trip {
        guard now.timeIntervalSince(said) >= receiptLimit else { return .sending }
        if let relay, !relay.reachesMac { return .failed(.offline(relay)) }
        return .failed(.noReply)
    }
}

/// 一句说出去的话的记录：对 Cue 说的消息（`host` 是 Cue 住的那台 Mac），或发给会话的投送请求。气泡、重发、撤回都按它。
nonisolated enum Said: Equatable, Sendable {
    case cue(CueMessage, host: String?)
    case request(DeliveryRequest)

    var id: UUID {
        switch self {
        case .cue(let message, _): message.id
        case .request(let request): request.id
        }
    }

    /// 存储格式正文。
    var content: String {
        switch self {
        case .cue(let message, _): message.text
        case .request(let request): request.content
        }
    }

    /// 接收它的那台 Mac。
    var host: String? {
        switch self {
        case .cue(_, let host): host
        case .request(let request): request.hostID
        }
    }

    var deadline: Date? {
        switch self {
        case .cue(let message, _): Speech.deadline(said: message.createdAt, delivered: message.deliveredAt)
        case .request(let request): Speech.deadline(request)
        }
    }

    func trip(now: Date, relay: SyncStatus?) -> Speech.Trip {
        switch self {
        case .cue(let message, _): Speech.trip(said: message.createdAt, delivered: message.deliveredAt, now: now, relay: relay)
        case .request(let request): Speech.trip(request, now: now, relay: relay)
        }
    }

    /// 往返时间（发给会话的，结果回到本机时才有）。
    var roundTrip: Duration? {
        if case .request(let request) = self { request.roundTrip } else { nil }
    }

    /// 重发写到哪：同一个去处、同样的方式。
    var listener: Listener {
        switch self {
        case .cue: .cue
        case .request(let request): .session(request.target, host: request.hostID, mode: request.mode.known ?? .followUp, card: request.cardID)
        }
    }
}

/// 说的话写到哪：对 Cue 说（写一条你的消息，Cue 住的那台 Mac 读到再交给它），或发给一个会话（写一条指定会话所在 Mac 的投送请求）。
nonisolated enum Listener: Equatable, Sendable {
    case cue
    case session(SendTarget, host: String, mode: DeliveryMode, card: UUID?)

    static func session(_ session: PiSessionState, mode: DeliveryMode, card: UUID? = nil) -> Listener {
        .session(session.target, host: session.hostID, mode: mode, card: card)
    }
}
