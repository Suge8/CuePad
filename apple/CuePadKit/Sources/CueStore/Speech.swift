import Foundation

public enum Speech {
  public enum Trip: Equatable, Sendable {
    case sending
    case preparing(String)
    case sent
    case delivered
    case unconfirmed(String)
    case failed(Failure)

    public var failure: Failure? { if case .failed(let failure) = self { failure } else { nil } }

    public var unconfirmedReason: String? { if case .unconfirmed(let reason) = self { reason } else { nil } }

    public var awaitingResult: Bool {
      if case .preparing = self { return true }
      return inTransit
    }

    public var inTransit: Bool { self == .sending || self == .sent }
  }

  public enum Activity: Sendable { case pending, unconfirmed }

  public static func activity(_ request: DeliveryRequest, at moment: Moment) -> Activity? {
    guard request.status != .known(.preparing) else { return nil }
    switch trip(request, at: moment) {
    case .preparing, .failed: return nil
    case .sending, .sent: return .pending
    case .delivered, .unconfirmed: return .unconfirmed
    }
  }

  public enum Failure: Hashable, Sendable {
    case reported(String)
  }

  public static let unconfirmedReason = ShownText("送达尚未确认，可能已经执行，不会自动重发")

  public static let sendLimit: TimeInterval = 15

  public static let receiptLimit: TimeInterval = 60

  public static let cueWait: TimeInterval = 20

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

    public func isLocal(_ host: String?) -> Bool { host != nil && host == localHost }

    public func reachableSince(_ host: String?) -> Date? { isLocal(host) ? .distantPast : reachableSince }

    public func seesPresence(of host: String) -> Bool { !isLocal(host) && reachableSince != nil }
  }

  public static func trip(said: Date, delivered: Date?, reachedServer: Bool, host: String?, at moment: Moment) -> Trip {
    delivered != nil ? .delivered : waiting(since: said, reachedServer: reachedServer, host: host, at: moment)
  }

  public static func trip(_ request: DeliveryRequest, at moment: Moment) -> Trip {
    if awaitsDispatch(request) {
      if let expires = expiry(of: request), moment.now >= expires { return .unconfirmed(unconfirmedReason.text) }
      if request.status == .known(.preparing) { return .preparing(ShownText("尚未派发：\((request.reason ?? ShownText("等待目标就绪")).embedded)").text) }
      return request.reachedServer && !moment.isLocal(request.hostID) ? .sent : .sending
    }
    switch request.status.known {
    case .pending, .preparing, .executing, .confirming: return phase(request, at: moment)
    case .unconfirmed: return .unconfirmed(request.reason?.text ?? unconfirmedReason.text)
    case nil: return .unconfirmed(unconfirmedReason.text)
    case .succeeded: return .delivered
    case .failed: return .failed(.reported(request.failure ?? DeliveryRequest.unexplainedFailure))
    }
  }

  private static func awaitsDispatch(_ request: DeliveryRequest) -> Bool {
    request.status.known.map(DeliveryStatus.waiting.contains) == true
  }

  static func expiry(of request: DeliveryRequest) -> Date? {
    guard awaitsDispatch(request) else { return nil }
    return request.dispatchDeadline?.addingTimeInterval(receiptLimit)
  }

  public static func deadline(said: Date, delivered: Date?, reachedServer: Bool, host: String?, at moment: Moment) -> Date? {
    guard delivered == nil else { return nil }
    return due(said: said, reachedServer: reachedServer, host: host, at: moment)
  }

  public static func deadline(_ request: DeliveryRequest) -> Date? {
    guard request.isOpen else { return nil }
    return awaitsDispatch(request) ? expiry(of: request) : request.deadlineAt
  }

  public static func failedAt(_ request: DeliveryRequest, at moment: Moment) -> Date? {
    guard case .failed = trip(request, at: moment) else { return nil }
    return request.completedAt ?? request.modifiedAt
  }

  public static func undelivered(_ requests: [DeliveryRequest], at moment: Moment) -> Int {
    requests.count { request in
      guard request.mode == .known(.send) else { return false }
      return trip(request, at: moment).failure != nil
    }
  }

  private static func phase(_ request: DeliveryRequest, at moment: Moment) -> Trip {
    guard let deadline = request.deadlineAt, moment.now < deadline else { return .unconfirmed(unconfirmedReason.text) }
    return moment.isLocal(request.hostID) ? .sending : .sent
  }

  private static func waiting(since said: Date, reachedServer: Bool, host: String?, at moment: Moment) -> Trip {
    if let due = due(said: said, reachedServer: reachedServer, host: host, at: moment), moment.now >= due { return .unconfirmed(unconfirmedReason.text) }
    return reachedServer && !moment.isLocal(host) ? .sent : .sending
  }

  private static func due(said: Date, reachedServer: Bool, host: String?, at moment: Moment) -> Date? {
    moment.reachableSince(host).map { since in
      max(said, since).addingTimeInterval(reachedServer || moment.isLocal(host) ? receiptLimit : sendLimit)
    }
  }
}
