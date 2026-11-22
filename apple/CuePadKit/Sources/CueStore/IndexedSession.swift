import Foundation

public struct SessionUpsert: Sendable {
  public var session: IndexedSession
  public var checkpoint: Data?
  public var transcript: SessionTranscript?

  public init(session: IndexedSession, checkpoint: Data?, transcript: SessionTranscript?) {
    self.session = session
    self.checkpoint = checkpoint
    self.transcript = transcript
  }
}

public struct IndexedSessionStart: Equatable, Sendable {
  public var id: String
  public var checkpoint: Data?
  public var hasMessages: Bool

  public init(id: String, checkpoint: Data?, hasMessages: Bool) {
    self.id = id
    self.checkpoint = checkpoint
    self.hasMessages = hasMessages
  }
}

public struct IndexedSession: Identifiable, Equatable, Sendable {
  public let id: String
  public var path: String
  public var cwd: String
  public var title: String
  public var lastActivityAt: Date
  public var agent: AgentKind
  public var model: ModelKey?
  public var thinking: String?

  public init(
    id: String, path: String, cwd: String, title: String = "", lastActivityAt: Date, agent: AgentKind = .pi, model: ModelKey? = nil, thinking: String? = nil
  ) {
    self.id = id
    self.path = path
    self.cwd = cwd
    self.title = title
    self.lastActivityAt = lastActivityAt
    self.agent = agent
    self.model = model
    self.thinking = thinking
  }
}

extension IndexedSession: Record {
  static let table = Table.piSessions
  static let columns = ["id", "path", "cwd", "title", "lastActivityAt", "agent", "model", "thinking"]
  var bindings: [any SQLBindable] { [id, path, cwd, title, lastActivityAt, agent.rawValue, model.map(JSONColumn.encode), thinking] }
  init(row: Row) {
    self.init(
      id: row.text(0), path: row.text(1), cwd: row.text(2), title: row.text(3),
      lastActivityAt: row.date(4), agent: AgentKind(rawValue: row.text(5))!,
      model: JSONColumn.decode(ModelKey.self, from: row.textOrNil(6)), thinking: row.textOrNil(7))
  }
}
