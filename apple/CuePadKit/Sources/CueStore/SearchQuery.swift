import Foundation

public struct SearchQuery: Sendable, ExpressibleByStringLiteral {
  public var text: String
  public var projects: Set<UUID>?
  public var hasAttachments: Bool?
  public var isTask: Bool?
  public var sent: SendCondition
  public var modifiedIn: ClosedRange<Date>?
  public var inTrash: Bool

  public init(
    text: String = "", projects: Set<UUID>? = nil, hasAttachments: Bool? = nil, isTask: Bool? = nil, sent: SendCondition = .any,
    modifiedIn: ClosedRange<Date>? = nil, inTrash: Bool = false
  ) {
    self.text = text
    self.projects = projects
    self.hasAttachments = hasAttachments
    self.isTask = isTask
    self.sent = sent
    self.modifiedIn = modifiedIn
    self.inTrash = inTrash
  }

  public init(stringLiteral value: String) { self.init(text: value) }

  var hasCardFilters: Bool { projects != nil || hasAttachments != nil || isTask != nil || sent != .any || modifiedIn != nil }
}

public enum SendCondition: Equatable, Sendable {
  case any
  case never
  case sent(kind: Open<SendTargetKind>? = nil, name: String? = nil)
}

public struct SearchResults: Sendable {
  public var projects: [Project]
  public var cards: [Card]
  public var totalCards: Int
}
