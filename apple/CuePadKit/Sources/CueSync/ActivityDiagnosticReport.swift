import Foundation

/// 取证不是业务状态：只保存系统标识、时刻与固定原因，不保存正文、令牌、提问或额度。
/// contentObserved 是 App 看见系统内容的时刻，不是 APNs 投递时刻，也不是屏幕展示确认。
public struct ActivityDiagnosticReport: Codable, Sendable {
  public static let eventLimit = 96
  public static let retention: TimeInterval = 7 * 24 * 60 * 60
  public let device: String
  public var events: [Event]

  public struct Event: Codable, Sendable {
    public enum Action: String, Codable, Sendable {
      case processStarted, restore, request, created, blocked, endRequested, invalidated
      case stateObserved, contentObserved, destinationWrite, destinationRemove, destinationResult, appPhase
    }

    public var at: Date
    public var run: UUID
    public var sequence: Int
    public var build: String
    public var action: Action
    public var activity: String?
    public var reason: String?
    public var sourceAt: Date?
    public var contentTag: String?
    public var tokenTag: String?
    public var foreground: Bool?
    public var errorDomain: String?
    public var errorCode: Int?

    public init(
      at: Date = .now, run: UUID, sequence: Int, build: String, action: Action, activity: String? = nil,
      reason: String? = nil, sourceAt: Date? = nil, contentTag: String? = nil, tokenTag: String? = nil, foreground: Bool? = nil,
      errorDomain: String? = nil, errorCode: Int? = nil
    ) {
      self.at = at
      self.run = run
      self.sequence = sequence
      self.build = build
      self.action = action
      self.activity = activity
      self.reason = reason
      self.sourceAt = sourceAt
      self.contentTag = contentTag
      self.tokenTag = tokenTag
      self.foreground = foreground
      self.errorDomain = errorDomain
      self.errorCode = errorCode
    }
  }

  public init(device: String, events: [Event] = []) {
    self.device = device
    self.events = events
  }

  public mutating func append(_ event: Event) {
    let next = events.firstIndex { $0.run == event.run && $0.sequence > event.sequence }
    let afterRun = events.lastIndex { $0.run == event.run }.map { $0 + 1 }
    events.insert(event, at: next ?? afterRun ?? events.endIndex)
    // 先排顺再合并；不同内容版本、原因或错误不能被后来排到的同类事件抹掉。
    events = events.reduce(into: []) { kept, item in
      if let last = kept.last, [.contentObserved, .blocked].contains(item.action),
        last.run == item.run, last.action == item.action, last.activity == item.activity,
        last.reason == item.reason, last.sourceAt == item.sourceAt, last.contentTag == item.contentTag,
        last.foreground == item.foreground, last.errorDomain == item.errorDomain, last.errorCode == item.errorCode
      {
        kept.removeLast()
      }
      kept.append(item)
    }
    if events.count > Self.eventLimit { events.removeFirst(events.count - Self.eventLimit) }
  }
}
