import Foundation

public enum SessionScope: Sendable, Equatable {
  case live, ended, all, current
}

public struct SessionFolder: Sendable, Equatable {
  public var hostID: String
  public var folder: String
  public var sessionID: String
  public var projectID: UUID?
  public var count: Int
  public var macName: String

  public init(hostID: String, folder: String, sessionID: String, projectID: UUID?, count: Int, macName: String) {
    self.hostID = hostID
    self.macName = macName
    self.folder = folder
    self.sessionID = sessionID
    self.projectID = projectID
    self.count = count
  }
}

public struct SessionQuery: Sendable, Equatable {
  public var scope: SessionScope
  public var text: String?
  public var project: UUID?
  public var launchToken: String?
  public var id: UUID?
  public var pinned: Bool?
  public var excluding: [String] = []
  public var offset: Int
  public var limit: Int

  public init(
    scope: SessionScope = .all, text: String? = nil, project: UUID? = nil, launchToken: String? = nil, id: UUID? = nil,
    pinned: Bool? = nil, offset: Int = 0, limit: Int = 50
  ) {
    self.scope = scope
    self.text = text
    self.project = project
    self.launchToken = launchToken
    self.id = id
    self.pinned = pinned
    self.offset = offset
    self.limit = limit
  }

  public static let live = SessionQuery(scope: .live, limit: .max)
  public static let current = SessionQuery(scope: .current, limit: .max)
}

public struct SessionListItem: Identifiable, Sendable, Equatable {
  public var state: SessionState
  public var project: Project?
  public var delivery: DeliveryRequest?
  public var rename: DeliveryRequest?
  public var answer: DeliveryRequest?
  public var unsettled: [DeliveryRequest]
  public var task: SessionTask?
  public var id: UUID { state.id }
  public var home: UUID { project?.id ?? Project.defaultID }

  public init(
    state: SessionState, project: Project? = nil, delivery: DeliveryRequest? = nil, rename: DeliveryRequest? = nil, answer: DeliveryRequest? = nil,
    unsettled: [DeliveryRequest] = [], task: SessionTask? = nil
  ) {
    self.state = state
    self.project = project
    self.delivery = delivery
    self.rename = rename
    self.answer = answer
    self.unsettled = unsettled
    self.task = task
  }

  public func undelivered(at moment: Speech.Moment) -> Int { Speech.undelivered(unsettled, at: moment) }
}

public struct SessionTask: Sendable, Equatable {
  public var id: UUID
  public var isPinned: Bool
  public var title: String
  public var isDone: Bool

  public init(id: UUID, isPinned: Bool, title: String, isDone: Bool = false) {
    self.id = id
    self.isPinned = isPinned
    self.title = title
    self.isDone = isDone
  }
}

public struct SessionListPage: Sendable, Equatable {
  public var items: [SessionListItem]
  public var total: Int
}
