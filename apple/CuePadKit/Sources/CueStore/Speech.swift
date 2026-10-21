import Foundation

/// 说出去的一句话此刻到哪了：对 Cue 说的（你的 `CueMessage`）与发给会话的（说话、作答、命令等投送请求）同一条规则，
/// 只由记录与此刻（`Moment`）推出、不另存。App 的气泡、会话行与计数、各种进度、Cue 页的话在路上，与 Cue 的说话工具都读这里。
/// - 发送中：记录在，接收方还没回执。
/// - 已送达：请求成功；Cue 消息有 `deliveredAt`。
/// - 没能送达：请求失败（原因读 `DeliveryRequest.failure`）；本机同步此刻不通（话出不去、回执也回不来）；或同步通着满 `receiptLimit`
///   还没回执——Cue 消息没有 `deliveredAt`，请求还没被 Mac 领取（领取了在执行的不算超时，如唤醒已结束的会话）。超时只说这句话自己
///   没送到，不推断那台 Mac 在不在（Mac 在不在线、Cue 在不在睡觉与值班只看那台的在线记录 `MacPresence`）。
///   时限从写下与本机同步恢复两者里晚的那一刻算：断网时写下的话，恢复后有一整个时限等它传出去、回执回来。
///   记录仍在，回执来了就是已送达；同步恢复了就回到发送中。到点翻状态由 App 一处刷新"此刻"（`SpeechClock`），不轮询。
public enum Speech {
  public enum Trip: Equatable, Sendable {
    case sending
    case delivered
    case failed(Failure)

    public var failure: Failure? { if case .failed(let failure) = self { failure } else { nil } }
  }

  public enum Failure: Hashable, Sendable {
    /// 接收方说没送到（`DeliveryRequest.failure`）
    case reported(String)
    /// 本机同步此刻不通：话还没离开这台设备，或回执回不来
    case offline
    /// 同步通着过了时限没回执：接收方那台 Mac 一直没收下这句
    case timedOut
  }

  // MARK: 时限（说的话的各段等待只在这里定）

  /// 等回执的时限（会话与 Cue 共用）。一条话正常的往返：发出方立即上传（多数 1 秒内，偶尔约 10 秒，issue #2）、Mac 主动拉取
  /// （每 2 秒）、交给 Agent 或 Cue（0.2 秒内）、回执立即上传、发出方主动拉取（每 2 秒），几秒就回来；实测最慢的约 21 秒（2026-10-14
  /// 手机对 Cue 说的话，当时值班的 Mac 没在拉）。取 60 秒：是最慢实测的约三倍，活着的 Mac 慢一点也不会被报成没能送达；
  /// 又只是手机为在等的话主动拉取时长（`SyncPoller.Cadence.phone`，2 分钟）的一半——报了没能送达之后手机还接着拉一分钟，
  /// 晚到的回执照样拉回来、气泡自己变成已送达。
  public static let receiptLimit: TimeInterval = 60

  /// Cue 的说话工具（say、answer）写下请求后等结果多久。这一轮停在这里等，所以比 `receiptLimit` 短得多：Cue 多半运行在会话所在的
  /// 那台 Mac 上，本机执行与唤醒已结束的会话都在 1 秒内有结果，加上一次暂时性错误的重试（`retryDelay`）也在 10 秒内；
  /// 跨 Mac 的往返大多几秒。取 20 秒覆盖这些；没交到 Cue 手上的失败不丢，写进它下一轮的变化并立即叫醒它（`CueChange.Kind.undelivered`）。
  public static let cueWait: TimeInterval = 20

  /// Mac 执行器遇上暂时性错误（会话正在起、还没连上桥）后隔多久重试一次。假扩展与真实 Pi 起来后连上桥都在 0.3 秒内
  /// （桥用 kqueue 盯 socket 目录），取 2 秒留出余量；执行器按先后一条条执行，等得再久会拖住后面的请求。
  static let retryDelay: Duration = .seconds(2)

  // MARK: 规则

  /// 推出到哪了的外部输入：此刻，与本机同步从什么时候起通着（nil：此刻不通）。接收方就是本机（`localHost`）时不经同步，一直算通；
  /// 命令行里的 Cue 工具与它的 Mac 在一起，同样按一直通着算（`always`）。
  public struct Moment: Equatable, Sendable {
    public var now: Date
    public var reachableSince: Date?
    public var localHost: String?

    public init(now: Date, reachableSince: Date?, localHost: String? = nil) {
      self.now = now
      self.reachableSince = reachableSince
      self.localHost = localHost
    }

    /// 同步一直通着。
    public static func always(at now: Date = .now) -> Moment { Moment(now: now, reachableSince: .distantPast) }

    /// 到 `host` 那台 Mac 的同步从什么时候起通着；nil 是此刻不通。
    public func reachableSince(_ host: String?) -> Date? {
      host != nil && host == localHost ? .distantPast : reachableSince
    }
  }

  /// 对 Cue 说的一句：`said` 是写下的时刻，`delivered` 是交给 Cue 的时刻，`host` 是 Cue 运行的那台 Mac。
  public static func trip(said: Date, delivered: Date?, host: String?, at moment: Moment) -> Trip {
    delivered != nil ? .delivered : waiting(since: said, host: host, at: moment)
  }

  public static func trip(_ request: DeliveryRequest, at moment: Moment) -> Trip {
    switch request.status.known {
    case .pending: waiting(since: request.createdAt, host: request.hostID, at: moment)
    case .executing: .sending
    case .succeeded: .delivered
    case .failed, nil: .failed(.reported(request.failure ?? DeliveryRequest.unexplainedFailure))
    }
  }

  /// 还在等回执的话到这一刻就算超时；已有回执、已被领取或此刻同步不通（不会到点，恢复时输入本身就变了）为 nil。
  public static func deadline(said: Date, delivered: Date?, host: String?, at moment: Moment) -> Date? {
    guard delivered == nil, let since = moment.reachableSince(host) else { return nil }
    return max(said, since).addingTimeInterval(receiptLimit)
  }

  public static func deadline(_ request: DeliveryRequest, at moment: Moment) -> Date? {
    request.status == .known(.pending) ? deadline(said: request.createdAt, delivered: nil, host: request.hostID, at: moment) : nil
  }

  /// 没能送达的那一刻（会话行"你看过之后不再标没能送达"据此比较）：失败写回的时刻，或超时的那一刻；还没失败为 nil。
  public static func failedAt(_ request: DeliveryRequest, at moment: Moment) -> Date? {
    guard case .failed = trip(request, at: moment) else { return nil }
    return request.completedAt ?? deadline(request, at: moment) ?? moment.now
  }

  /// 这些请求里此刻没能送达的话有几句：说的话（`DeliveryMode.send`）里失败的与超时的（会话行与会话页顶栏的"N 句没送到"）。
  public static func undelivered(_ requests: [DeliveryRequest], at moment: Moment) -> Int {
    requests.count { request in
      guard request.mode == .known(.send) else { return false }
      if case .failed = trip(request, at: moment) { return true } else { return false }
    }
  }

  private static func waiting(since said: Date, host: String?, at moment: Moment) -> Trip {
    guard let since = moment.reachableSince(host) else { return .failed(.offline) }
    return moment.now >= max(said, since).addingTimeInterval(receiptLimit) ? .failed(.timedOut) : .sending
  }
}
