import Foundation

/// 你对一样东西的注意（同步，各端都写）：Cue 页读到哪、会话看到哪、标为未读、灵感今天先不做。
/// 一条只记一个时刻，就记成这一行的修改时间，没有别的值：同步时两版按修改时间取晚的（`CueStore.applyVersion`），本机也只往后挪（`CueStore.mark`），
/// 两台各记各的，谁也冲不掉另一台更晚的那一下。不记在它说的那样东西身上：那条记录的真改动与"看了一眼"并发时，整条取胜会带走另一边的。
public enum Mark: Hashable, Sendable {
  /// Cue 页读到的那条 Cue 的话写下的时刻（新消息的规则在 `CueStore.cueUnread`）
  case cueRead
  /// 会话页显示着它（会话 id）
  case sessionSeen(String)
  /// 标为未读
  case sessionUnread(String)
  /// 灵感划掉：当天不再提（`CueStore.pendingIdeas`）
  case ideaSkipped(UUID)

  var kind: String {
    switch self {
    case .cueRead: "cueRead"
    case .sessionSeen: "sessionSeen"
    case .sessionUnread: "sessionUnread"
    case .ideaSkipped: "ideaSkipped"
    }
  }

  /// 卡片按库里的写法（小写），查询直接与 `cards.id` 比。
  var subject: String {
    switch self {
    case .cueRead: ""
    case .sessionSeen(let session), .sessionUnread(let session): session
    case .ideaSkipped(let card): card.uuidString.lowercased()
    }
  }

  var id: UUID { DeterministicID.uuid("mark/\(kind)/\(subject)") }
}

extension Mark: SyncedColumns {
  static let fields: [Field] = [.plain("id"), .plain("kind"), .plain("subject"), .plain("modifiedAt")]
}

/// 一个会话的两下（`Mark.sessionSeen`、`Mark.sessionUnread`）。
public struct SessionMarks: Equatable, Sendable {
  public var seen: Date?
  public var unread: Date?

  public init(seen: Date? = nil, unread: Date? = nil) {
    self.seen = seen
    self.unread = unread
  }
}

extension SessionState {
  /// 新回复里没看过的那一种（唯一的规则）：停下了、这次停下或你标未读之后还没看过。只算 `unreadWindow` 内的：更早的不再是"新"回复。
  public func isUnread(_ marks: SessionMarks?, at now: Date) -> Bool {
    isSettledReply && unreadSince(marks) > (marks?.seen ?? .distantPast) && now < unreadUntil(marks)
  }

  /// 不再算新回复的时刻（读的一方按它登记到点重读）。
  public func unreadUntil(_ marks: SessionMarks?) -> Date { unreadSince(marks).addingTimeInterval(Self.unreadWindow) }

  /// 新回复从哪一刻算：这次停下，或之后你标未读的那一下。
  private func unreadSince(_ marks: SessionMarks?) -> Date { max(stateSince, marks?.unread ?? .distantPast) }

  public func canMarkUnread(_ marks: SessionMarks?, at now: Date) -> Bool { isSettledReply && !isUnread(marks, at: now) }

  public static let unreadWindow: TimeInterval = 7 * 86_400

  public var hasStarted: Bool { lastPrompt != nil || lastReply != nil || pendingPrompt != nil }

  private var isSettledReply: Bool { runtimeState == .known(.settled) && hasStarted }
}

extension CueStore {
  /// 记下这一下（`moment` 不给是此刻）；只往后挪，没挪（别处记过更晚的）不写、不同步。
  public func mark(_ mark: Mark, at moment: Date? = nil) throws {
    let moment = moment ?? .stamp
    try write {
      try db.run(
        """
        INSERT INTO marks (id, kind, subject, modifiedAt) VALUES (?1, ?2, ?3, ?4)
        ON CONFLICT(id) DO UPDATE SET modifiedAt = excluded.modifiedAt WHERE excluded.modifiedAt > marks.modifiedAt
        """, [mark.id, mark.kind, mark.subject, moment])
    }
  }

  /// 各会话的两下，按会话 id。
  public func sessionMarks() throws -> [String: SessionMarks] {
    var marks: [String: SessionMarks] = [:]
    try db.query("SELECT kind, subject, modifiedAt FROM marks WHERE kind IN ('sessionSeen', 'sessionUnread')") { ($0.text(0), $0.text(1), $0.date(2)) }
      .forEach { kind, session, at in
        if kind == "sessionSeen" { marks[session, default: SessionMarks()].seen = at } else { marks[session, default: SessionMarks()].unread = at }
      }
    return marks
  }

  func sessionMarks(_ session: String) throws -> SessionMarks {
    try db.query("SELECT kind, modifiedAt FROM marks WHERE kind IN ('sessionSeen', 'sessionUnread') AND subject = ?", [session]) { ($0.text(0), $0.date(1)) }
      .reduce(into: SessionMarks()) { marks, row in
        if row.0 == "sessionSeen" { marks.seen = row.1 } else { marks.unread = row.1 }
      }
  }
}
