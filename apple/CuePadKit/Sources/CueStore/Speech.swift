import Foundation

/// 说出去的一句话此刻到哪了：对 Cue 说的（你的 `CueMessage`）与发给会话的（说话、作答、命令等投送请求）同一条规则，
/// 只由记录、它的同步元数据（服务器收下过没有，`reachedServer`）与此刻（`Moment`）推出、不另存。App 的气泡、会话行与计数、各种进度、
/// Cue 页的话在路上，与 Cue 的说话工具都读这里。
/// - 发送中：还没离开这台设备（服务器没收下过）。接收方就是本机时不经服务器，回执前一直是发送中。
/// - 已发出：服务器收下了（或接收的 Mac 已领取），还没回执。这之后本机同步断开不改变它：话已经在服务器上，回执晚点回来而已。
/// - 已送达：请求成功；Cue 消息有 `deliveredAt`。
/// - 没能送达：请求失败（原因读 `DeliveryRequest.failure`）；写下满 `sendLimit` 还没离开这台设备（`unsent`）；或已发出、同步通着满
///   `receiptLimit` 还没回执（`timedOut`）——Cue 消息没有 `deliveredAt`，请求还没被 Mac 领取（领取了在执行的不算超时，如唤醒已结束的会话）。
///   每句只看自己的证据：一次拉取或上传失败（全局同步状态一时不通）不让别的话变红，已发出的话更不受影响。超时只说这句话自己没送到，
///   不推断那台 Mac 在不在（Mac 在不在线、Cue 在不在睡觉与值班只看那台的在线记录 `MacPresence`）。
///   两个时限都从写下与本机同步恢复两者里晚的那一刻算：断网时写下的话，恢复后有一整段时限传出去、等回执。
///   记录仍在，传出去了就回到已发出，回执来了就是已送达。到点翻状态由 App 一处刷新"此刻"（`SpeechClock`），不轮询。
public enum Speech {
  public enum Trip: Equatable, Sendable {
    case sending
    case sent
    case delivered
    case failed(Failure)

    public var failure: Failure? { if case .failed(let failure) = self { failure } else { nil } }

    /// 还在路上（发送中或已发出）：在等它的进度、停用的按钮都按这个。
    public var inTransit: Bool { self == .sending || self == .sent }
  }

  public enum Failure: Hashable, Sendable {
    /// 接收方说没送到（`DeliveryRequest.failure`）
    case reported(String)
    /// 写下满 `sendLimit` 还没离开这台设备：本机同步不通，或这句一直没传上去
    case unsent
    /// 已发出，同步通着过了时限没回执：接收方那台 Mac 一直没收下这句
    case timedOut
  }

  // MARK: 时限（说的话的各段等待只在这里定）

  /// 写下到服务器收下的时限。实测（2026-10-14～24 真实库，手机对 Cue 说的 201 句）中位 0.44 秒、p95 2 秒，10-15 之后没有超过 3 秒的；
  /// 一次失败后发送者 0、4、12 秒各重试一次。取 15 秒：一次暂时失败、重试一两次仍传得出去的不算没能送达；
  /// 又远短于等回执的 60 秒——真断网时尽早告诉你这句没出去。
  public static let sendLimit: TimeInterval = 15

  /// 已发出后等回执的时限（会话与 Cue 共用）。一条话正常的往返：Mac 被门铃叫来拉或按节奏拉、交给 Agent 或 Cue（0.2 秒内）、回执立即上传、
  /// 发出方同样拉到（docs/sync.md「拉取节奏与门铃」），几秒就回来；实测最慢的约 21 秒（2026-10-14 手机对 Cue 说的话，当时值班的 Mac 没在拉）。取 60 秒：
  /// 是最慢实测的约三倍，活着的 Mac 慢一点也不会被报成没能送达；又只是手机为在等的话主动拉取时长（`SyncPoller.Cadence.phone`，2 分钟）的一半——
  /// 报了没能送达之后手机还接着拉一分钟，晚到的回执照样拉回来、气泡自己变成已送达。
  public static let receiptLimit: TimeInterval = 60

  /// Cue 的说话工具（say、answer）写下请求后等结果多久。这一轮停在这里等，所以比 `receiptLimit` 短得多：Cue 多半运行在会话所在的
  /// 那台 Mac 上，本机执行与唤醒已结束的会话都在 1 秒内有结果，加上一次暂时性错误的重试（`retryDelay`）也在 10 秒内；
  /// 跨 Mac 的往返大多几秒。取 20 秒覆盖这些；没交到 Cue 手上的失败不丢，写进它下一轮的变化并立即叫醒它（`CueChange.Kind.undelivered`）。
  public static let cueWait: TimeInterval = 20

  /// Mac 执行器遇上暂时性错误（会话正在起、还没连上桥）后隔多久重试一次。假扩展与真实 Pi 起来后连上桥都在 0.3 秒内
  /// （桥用 kqueue 盯 socket 目录），取 2 秒留出余量；执行器按先后一条条执行，等得再久会拖住后面的请求。
  static let retryDelay: Duration = .seconds(2)

  // MARK: 规则

  /// 推出到哪了的外部输入：此刻，与本机同步从什么时候起通着（nil：此刻不通）。接收方就是本机（`localHost`）时不经同步；
  /// 命令行里的 Cue 工具与它的 Mac 在一起，按一直通着算（`always`）。
  public struct Moment: Equatable, Sendable {
    public var now: Date
    public var reachableSince: Date?
    public var localHost: String?

    public init(now: Date, reachableSince: Date?, localHost: String? = nil) {
      self.now = now
      self.reachableSince = reachableSince
      self.localHost = localHost
    }

    public static func always(at now: Date = .now) -> Moment { Moment(now: now, reachableSince: .distantPast) }

    /// 接收的就是这台 Mac：话不经服务器。
    public func isLocal(_ host: String?) -> Bool { host != nil && host == localHost }

    /// 到 `host` 那台 Mac 的同步从什么时候起通着；nil 是此刻不通。
    public func reachableSince(_ host: String?) -> Date? { isLocal(host) ? .distantPast : reachableSince }
  }

  /// 对 Cue 说的一句：`said` 是写下的时刻，`delivered` 是交给 Cue 的时刻，`reachedServer` 是服务器收下过它，`host` 是 Cue 运行的那台 Mac。
  public static func trip(said: Date, delivered: Date?, reachedServer: Bool, host: String?, at moment: Moment) -> Trip {
    delivered != nil ? .delivered : waiting(since: said, reachedServer: reachedServer, host: host, at: moment)
  }

  public static func trip(_ request: DeliveryRequest, at moment: Moment) -> Trip {
    switch request.status.known {
    case .pending: waiting(since: request.createdAt, reachedServer: request.reachedServer, host: request.hostID, at: moment)
    case .executing: moment.isLocal(request.hostID) ? .sending : .sent
    case .succeeded: .delivered
    case .failed, nil: .failed(.reported(request.failure ?? DeliveryRequest.unexplainedFailure))
    }
  }

  /// 还在等的话到这一刻就算没能送达；已有回执、已被领取，或已发出而此刻同步不通（不会到点，恢复时输入本身就变了）为 nil。
  public static func deadline(said: Date, delivered: Date?, reachedServer: Bool, host: String?, at moment: Moment) -> Date? {
    guard delivered == nil else { return nil }
    return due(said: said, reachedServer: reachedServer, host: host, at: moment)?.at
  }

  public static func deadline(_ request: DeliveryRequest, at moment: Moment) -> Date? {
    guard request.status == .known(.pending) else { return nil }
    return deadline(said: request.createdAt, delivered: nil, reachedServer: request.reachedServer, host: request.hostID, at: moment)
  }

  /// 没能送达的那一刻（会话行"你看过之后不再标没能送达"据此比较）：失败写回的时刻，或到点的那一刻；还没失败为 nil。
  public static func failedAt(_ request: DeliveryRequest, at moment: Moment) -> Date? {
    guard case .failed = trip(request, at: moment) else { return nil }
    return request.completedAt ?? deadline(request, at: moment) ?? moment.now
  }

  /// 这些请求里此刻没能送达的话有几句：说的话（`DeliveryMode.send`）里失败的与到点的（会话行与会话页顶栏的"N 句没送到"）。
  public static func undelivered(_ requests: [DeliveryRequest], at moment: Moment) -> Int {
    requests.count { request in
      guard request.mode == .known(.send) else { return false }
      return trip(request, at: moment).failure != nil
    }
  }

  private static func waiting(since said: Date, reachedServer: Bool, host: String?, at moment: Moment) -> Trip {
    if let due = due(said: said, reachedServer: reachedServer, host: host, at: moment), moment.now >= due.at { return .failed(due.failure) }
    return reachedServer && !moment.isLocal(host) ? .sent : .sending
  }

  /// 在等的这一段到哪一刻算没能送达、算哪一种：本机接收的只等回执；没离开这台的等它传出去（同步不通时从写下算）；
  /// 已发出的等回执，同步不通时不计时（nil）。
  private static func due(said: Date, reachedServer: Bool, host: String?, at moment: Moment) -> (at: Date, failure: Failure)? {
    if moment.isLocal(host) { return (said.addingTimeInterval(receiptLimit), .timedOut) }
    guard reachedServer else { return (max(said, moment.reachableSince ?? said).addingTimeInterval(sendLimit), .unsent) }
    return moment.reachableSince.map { (max(said, $0).addingTimeInterval(receiptLimit), .timedOut) }
  }
}
