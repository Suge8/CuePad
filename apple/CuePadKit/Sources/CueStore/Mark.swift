import Foundation

public enum Mark: Hashable, Sendable {
  case cueRead
  case sessionSeen(String)
  case sessionUnread(String)
  case tier(String, CueTier)

  static let tierPrefix = "tier."

  var kind: String {
    switch self {
    case .cueRead: "cueRead"
    case .sessionSeen: "sessionSeen"
    case .sessionUnread: "sessionUnread"
    case .tier(_, let tier): Self.tierPrefix + tier.rawValue
    }
  }

  var subject: String {
    switch self {
    case .cueRead: ""
    case .sessionSeen(let session), .sessionUnread(let session), .tier(let session, _): session
    }
  }

  var id: UUID { DeterministicID.uuid("mark/\(kind)/\(subject)") }
}

extension Mark: SyncedColumns {
  static let fields: [Field] = [.plain("id"), .plain("kind"), .plain("subject"), .plain("modifiedAt")]
}

public struct SessionMarks: Equatable, Sendable {
  public var seen: Date?
  public var unread: Date?

  public init(seen: Date? = nil, unread: Date? = nil) {
    self.seen = seen
    self.unread = unread
  }
}

extension SessionState {
  public func isUnread(_ marks: SessionMarks?, at now: Date) -> Bool {
    isSettledReply && unreadSince(marks) > (marks?.seen ?? .distantPast) && now < unreadUntil(marks)
  }

  public func unreadUntil(_ marks: SessionMarks?) -> Date { unreadSince(marks).addingTimeInterval(Self.unreadWindow) }

  private func unreadSince(_ marks: SessionMarks?) -> Date { max(stateSince, marks?.unread ?? .distantPast) }

  public func canMarkUnread(_ marks: SessionMarks?, at now: Date) -> Bool { isSettledReply && !isUnread(marks, at: now) }

  public static let unreadWindow: TimeInterval = 7 * 86_400

  public var hasStarted: Bool { lastPrompt != nil || lastReply != nil || pendingPrompt != nil }

  private var isSettledReply: Bool { runtimeState == .known(.settled) && hasStarted }
}

extension CueStore {
  public func mark(_ mark: Mark, at moment: Date? = nil) throws {
    try write { try putMark(mark, at: moment ?? .stamp) }
  }

  func putMark(_ mark: Mark, at moment: Date) throws {
    try db.run(
      """
      INSERT INTO marks (id, kind, subject, modifiedAt) VALUES (?1, ?2, ?3, ?4)
      ON CONFLICT(id) DO UPDATE SET modifiedAt = excluded.modifiedAt WHERE excluded.modifiedAt > marks.modifiedAt
      """, [mark.id, mark.kind, mark.subject, moment])
  }

  public func sessionMarks() throws -> [String: SessionMarks] {
    var marks: [String: SessionMarks] = [:]
    try db.query(
      """
      SELECT kind, subject, modifiedAt FROM marks WHERE kind IN ('sessionSeen', 'sessionUnread')
        AND (modifiedAt >= ? OR subject IN (SELECT targetRef FROM deliveryRequests WHERE status <> ? AND targetRef IS NOT NULL))
      """, [timing.now().addingTimeInterval(-SessionState.unreadWindow), DeliveryStatus.succeeded.rawValue]
    ) { ($0.text(0), $0.text(1), $0.date(2)) }
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
