import Foundation

/// 说出去的一句话此刻到哪了：对 Cue 说的（你的 `CueMessage`）与发给会话的（说话、作答、命令的投送请求）同一条规则，
/// 只由记录与此刻推出、不另存。App 的气泡、提示词、Cue 在不在与 Cue 的说话工具（`CueTools`）都读这里；
/// 调用方只补一个输入：到接收方那台 Mac 的同步此刻通不通（`reachable`，本机就是接收方算通）。
/// - 发送中：记录在，接收方还没回执。
/// - 已送达：会话请求成功；Cue 消息有 `deliveredAt`。
/// - 没能送达：会话请求失败（原因读 `DeliveryRequest.failure`）；或过了 `receiptLimit` 还没回执——Cue 消息没有 `deliveredAt`，
///   会话请求还没被 Mac 领取（领取了在执行的不算超时，如唤醒已结束的会话）。超时的原因只有两种：本机同步不通，或 Mac 没有回应。
///   超时后记录仍在，回执来了就是已送达；到点翻状态由界面的睡眠任务刷新"此刻"（`deadline`），不轮询。
public enum Speech {
  public enum Trip: Equatable, Sendable {
    case sending
    case delivered
    case failed(Failure)
  }

  public enum Failure: Equatable, Sendable {
    /// 接收方说没送到（`DeliveryRequest.failure`）
    case reported(String)
    /// 过了时限没回执，本机同步不通：话还没离开这台设备，或回执回不来
    case offline
    /// 过了时限没回执，同步是通的：接收方那台 Mac 没有回应（睡着了、没开 CuePad）
    case noReply
  }

  // MARK: 时限（说的话的各段等待只在这里定）

  /// 等回执的时限（会话与 Cue 共用）。一条话正常的往返：发出方立即上传（多数 1 秒内，偶尔约 10 秒，issue #2）、Mac 主动拉取
  /// （每 2 秒）、交给 Agent 或 Cue（0.2 秒内）、回执立即上传、发出方主动拉取（每 2 秒），几秒就回来；实测最慢的约 21 秒（2026-10-14
  /// 手机对 Cue 说的话，当时值班的 Mac 没在拉）。取 60 秒：是最慢实测的约三倍，活着的 Mac 慢一点也不会被说成没有回应；
  /// 又只是手机为在等的话主动拉取时长（`SyncPoller.Cadence.phone`，2 分钟）的一半——报了没能送达之后手机还接着拉一分钟，
  /// 晚到的回执照样拉回来、气泡自己变成已送达。与连接测试的等待（`AppServices.ping`）一样长。
  public static let receiptLimit: TimeInterval = 60

  /// Cue 的说话工具（say、answer）写下请求后等结果多久。这一轮停在这里等，所以比 `receiptLimit` 短得多：Cue 多半住在会话所在的
  /// 那台 Mac 上，本机执行 1 秒内有结果，唤醒已结束的会话几秒，加上一次暂时性错误的重试（`retryDelay`）也在 10 秒内；
  /// 跨 Mac 的往返大多几秒。取 20 秒覆盖这些；没交到 Cue 手上的失败不丢，写进它下一轮的变化并立即叫醒它（`CueChange.Kind.undelivered`）。
  public static let cueWait: TimeInterval = 20

  /// Mac 执行器遇上暂时性错误（会话正在起、还没连上桥）后隔多久重试一次。假扩展与真实 Pi 起来后连上桥都在 1 秒左右
  /// （桥靠目录监听发现新 socket），取 2 秒留出余量；执行器按先后一条条执行，等得再久会拖住后面的请求。
  public static let retryDelay: Duration = .seconds(2)

  // MARK: 规则

  /// 对 Cue 说的一句：`said` 是写下的时刻，`delivered` 是交给 Cue 的时刻。
  public static func trip(said: Date, delivered: Date?, now: Date, reachable: Bool) -> Trip {
    delivered != nil ? .delivered : waiting(since: said, now: now, reachable: reachable)
  }

  public static func trip(_ request: DeliveryRequest, now: Date, reachable: Bool) -> Trip {
    switch request.status.known {
    case .pending: waiting(since: request.createdAt, now: now, reachable: reachable)
    case .executing: .sending
    case .succeeded: .delivered
    case .failed, nil: .failed(.reported(request.failure ?? DeliveryRequest.unexplainedFailure))
    }
  }

  /// 还在等回执的话到这一刻就算超时；已有回执（或已被领取）为 nil。
  public static func deadline(said: Date, delivered: Date?) -> Date? {
    delivered == nil ? said.addingTimeInterval(receiptLimit) : nil
  }

  public static func deadline(_ request: DeliveryRequest) -> Date? {
    request.status == .known(.pending) ? request.createdAt.addingTimeInterval(receiptLimit) : nil
  }

  private static func waiting(since said: Date, now: Date, reachable: Bool) -> Trip {
    guard now.timeIntervalSince(said) >= receiptLimit else { return .sending }
    return .failed(reachable ? .noReply : .offline)
  }
}
