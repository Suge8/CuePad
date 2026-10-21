import Foundation

/// 一个会话索引的写入：索引、检查点（nil：保留已存的）与同一次读会话文件得到的对话（见 `CueStore.upsertPiSessions`）。
public struct PiSessionUpsert: Sendable {
  public var session: IndexedSession
  public var checkpoint: Data?
  public var transcript: PiTranscript?

  public init(session: IndexedSession, checkpoint: Data?, transcript: PiTranscript?) {
    self.session = session
    self.checkpoint = checkpoint
    self.transcript = transcript
  }
}

/// 一条会话索引从哪接着读（`piIndexStarts`）：会话 id、检查点、本机有没有它的对话。
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

/// 仅本机：Agent 会话历史索引的一条（会话文件路径与工作目录，OpenCode 的是它数据库里的会话）。检查点（含读取偏移）另存，用 `piCheckpoint(of:)` 读取。不同步。
public struct IndexedSession: Identifiable, Equatable, Sendable {
  public let id: String
  public var path: String
  public var cwd: String
  public var title: String
  public var lastActivityAt: Date
  public var agent: AgentKind

  public init(id: String, path: String, cwd: String, title: String = "", lastActivityAt: Date, agent: AgentKind = .pi) {
    self.id = id
    self.path = path
    self.cwd = cwd
    self.title = title
    self.lastActivityAt = lastActivityAt
    self.agent = agent
  }
}

extension IndexedSession: Record {
  static let table = Table.piSessions
  static let columns = ["id", "path", "cwd", "title", "lastActivityAt", "agent"]
  var bindings: [any SQLBindable] { [id, path, cwd, title, lastActivityAt, agent.rawValue] }
  init(row: Row) {
    self.init(
      id: row.text(0), path: row.text(1), cwd: row.text(2), title: row.text(3),
      lastActivityAt: row.date(4), agent: row.textOrNil(5).flatMap(AgentKind.init(rawValue:)) ?? .pi)
  }
}
