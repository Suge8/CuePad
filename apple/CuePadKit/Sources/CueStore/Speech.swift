import Foundation

/// 一句话的送达证据，由记录、服务器收下过没有与此刻推出，不另存。
/// 发送中与已发出仍在等；超时、领取后缺少结果或本版本不认识的状态只说明未确认，不证明未交出。
/// 只有接收方明确拒绝才是失败。未确认不自动重发，晚到的正证据可以让它变为已送达。
/// 两段等待时限只在同步通着时走；到点由 App 的 `SpeechClock` 刷新此刻，不轮询。
public enum Speech {
  public enum Trip: Equatable, Sendable {
    case sending
    case sent
    case delivered
    case unconfirmed(String)
    case failed(Failure)

    public var failure: Failure? { if case .failed(let failure) = self { failure } else { nil } }

    public var unconfirmedReason: String? { if case .unconfirmed(let reason) = self { reason } else { nil } }

    /// 仍在等进度；未确认已结束等待，不显示运行中，也不因此授权安全重发。
    public var inTransit: Bool { self == .sending || self == .sent }
  }

  public enum Failure: Hashable, Sendable {
    /// 接收方说没送到（`DeliveryRequest.failure`）
    case reported(String)
  }

  public static var unconfirmedReason: String { String(localized: "送达尚未确认，可能已经执行，不会自动重发") }

  // MARK: 时限（说的话的各段等待只在这里定）

  /// 等服务器回执的窗口；到点只表示缺少确认，不证明服务器未收到。
  public static let sendLimit: TimeInterval = 15

  /// 等接收方回执的窗口；本机不经服务器，也用这一段。
  public static let receiptLimit: TimeInterval = 60

  /// Cue 工具等结果的窗口；到点如实返回未确认，不保证未来一定有结果。
  public static let cueWait: TimeInterval = 20

  // MARK: 规则

  /// 推出到哪了的外部输入：此刻，与本机同步从什么时候起通着（nil：此刻不通）。接收方就是本机（`localHost`）时不经同步；
  /// Cue 的说话工具与 Cue 在同一台 Mac 上：按一直通着算（`always`）、那台就是本机（`CueTools.spoken`）。
  public struct Moment: Equatable, Sendable {
    public var now: Date
    public var reachableSince: Date?
    public var localHost: String?

    public init(now: Date, reachableSince: Date?, localHost: String? = nil) {
      self.now = now
      self.reachableSince = reachableSince
      self.localHost = localHost
    }

    public static func always(at now: Date = .now, localHost: String? = nil) -> Moment {
      Moment(now: now, reachableSince: .distantPast, localHost: localHost)
    }

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
    case .unconfirmed: .unconfirmed(request.failureReason?.text ?? unconfirmedReason)
    case nil: .unconfirmed(unconfirmedReason)
    case .succeeded: .delivered
    case .failed: .failed(.reported(request.failure ?? DeliveryRequest.unexplainedFailure))
    }
  }

  /// 等待到这一刻转为未确认；已有回执、已被领取或此刻同步不通时为 nil。
  public static func deadline(said: Date, delivered: Date?, reachedServer: Bool, host: String?, at moment: Moment) -> Date? {
    guard delivered == nil else { return nil }
    return due(said: said, reachedServer: reachedServer, host: host, at: moment)
  }

  public static func deadline(_ request: DeliveryRequest, at moment: Moment) -> Date? {
    guard request.status == .known(.pending) else { return nil }
    return deadline(said: request.createdAt, delivered: nil, reachedServer: request.reachedServer, host: request.hostID, at: moment)
  }

  /// 明确拒绝的写回时刻；超时和其他未确认不算失败。
  public static func failedAt(_ request: DeliveryRequest, at moment: Moment) -> Date? {
    guard case .failed = trip(request, at: moment) else { return nil }
    return request.completedAt ?? request.modifiedAt
  }

  /// 说的话里明确未送达的句数；未确认不计入。
  public static func undelivered(_ requests: [DeliveryRequest], at moment: Moment) -> Int {
    requests.count { request in
      guard request.mode == .known(.send) else { return false }
      return trip(request, at: moment).failure != nil
    }
  }

  private static func waiting(since said: Date, reachedServer: Bool, host: String?, at moment: Moment) -> Trip {
    if let due = due(said: said, reachedServer: reachedServer, host: host, at: moment), moment.now >= due { return .unconfirmed(unconfirmedReason) }
    return reachedServer && !moment.isLocal(host) ? .sent : .sending
  }

  private static func due(said: Date, reachedServer: Bool, host: String?, at moment: Moment) -> Date? {
    moment.reachableSince(host).map { since in
      max(said, since).addingTimeInterval(reachedServer || moment.isLocal(host) ? receiptLimit : sendLimit)
    }
  }
}
