import Foundation

public struct HandOffPlan: Equatable, Sendable {
  public enum Destination: Equatable, Sendable {
    case session(id: String, title: String, host: String?)
    case launch(project: UUID, host: String)
  }

  public var leaf: UUID
  public var destination: Destination
  public var opensSession: Bool { if case .session = destination { false } else { true } }
  public var name: String?
}

public struct CueBoard: Equatable, Sendable {
  public var tasks: [CueBoardItem]
  public var sessions: [SessionState]

  public var inProgress: [CueWork] { tasks.filter { $0.task.status == .inProgress }.map(CueWork.task) + sessions.map(CueWork.session) }

  public var active: [CueWork] { tasks.filter(\.isActive).map(CueWork.task) + sessions.map(CueWork.session) }
}

public enum CueWork: Identifiable, Equatable, Sendable {
  case task(CueBoardItem)
  case session(SessionState)

  public var id: String {
    switch self {
    case .task(let item): "task/\(item.id.uuidString)"
    case .session(let state): "session/\(state.sessionID)"
    }
  }

  public var task: Card? { if case .task(let item) = self { item.task } else { nil } }

  public var sessions: [SessionState] { CueAgents.sessions(in: [self]) }
}

public struct CueBoardItem: Identifiable, Equatable, Sendable {
  public var task: Card
  public var progress: TaskProgress?
  public var leaves: [CueBoardLeaf]
  public var id: UUID { task.id }
  public var isActive: Bool { leaves.contains(where: \.isActive) }
  public var session: SessionState? { leaves.lazy.compactMap(\.session).first }
  public var reaching: Bool { leaves.contains { $0.launching || $0.sending } }
}

public struct CueBoardLeaf: Equatable, Sendable {
  public var leaf: Card
  public var session: SessionState?
  public let handoffs: [DeliveryRequest]
  private let activity: Set<DeliveryMode>
  public var launching: Bool { activity.contains(.start) }
  public var sending: Bool { activity.contains(.send) }

  init(leaf: Card, session: SessionState?, handoffs: [DeliveryRequest], since: Date, at moment: Speech.Moment) {
    self.leaf = leaf
    self.session = session
    self.handoffs = handoffs
    self.since = since
    activity = Set(handoffs.filter { Speech.activity($0, at: moment) != nil }.compactMap(\.mode.known))
  }
  public var since: Date

  public var isActive: Bool { launching || sending || session.map { $0.state != .known(.ended) } ?? false }
}

public struct CueTaskDetail: Equatable, Sendable {
  public var task: Card
  public var progress: TaskProgress?
  public var leaves: [CueLeafDetail]
}

public struct CueLeafDetail: Equatable, Sendable {
  public var leaf: Card
  public var session: CueSessionDetail?
  public var handoffs: [DeliveryRequest]
}

public struct CueSessionDetail: Equatable, Sendable {
  public var session: SessionState
  public var recent: [ChatMessage]
  public var cueSent: Set<UUID>
  public var earlier: [ChatMessage]
}
