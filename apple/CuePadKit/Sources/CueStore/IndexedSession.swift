import Foundation

/// 一个会话索引的写入：索引、检查点（nil：保留已存的）与同一次读会话文件得到的对话（见 `CueStore.upsertSessions`）。
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

/// 一条会话索引从哪接着读（`indexStarts`）：会话 id、检查点、本机有没有它的对话。
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

/// 仅本机：Agent 会话历史索引的一条（会话文件路径与工作目录，OpenCode 的是它数据库里的会话）。检查点（含读取偏移）另存，用 `checkpoint(of:)` 读取。不同步。
/// `model`、`thinking` 是会话文件里最后记下的（各家的原值，没记的为 nil）：已结束的会话记录照它写，接着说时 Agent 用的就是它。
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
