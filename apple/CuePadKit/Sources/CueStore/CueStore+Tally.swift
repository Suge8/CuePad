import Foundation

public struct CueTally: Equatable, Sendable {
  public struct Wait: Identifiable, Equatable, Sendable {
    public var session: SessionState
    public var task: UUID?

    public init(session: SessionState, task: UUID?) {
      self.session = session
      self.task = task
    }

    public var id: String { "session/\(session.sessionID)" }
  }

  public struct Reply: Identifiable, Equatable, Sendable {
    public var session: SessionState
    public var task: UUID?

    public init(session: SessionState, task: UUID?) {
      self.session = session
      self.task = task
    }

    public var id: String { "reply/\(session.sessionID)" }
  }

  public var works: [CueWork]
  public var advancing: [CueWork] { works.filter { held(of: $0) == 0 } }

  public func held(of work: CueWork) -> Int {
    waiting.count { Self.holds(work, task: $0.task, session: $0.session.sessionID) }
      + replies.count { Self.holds(work, task: $0.task, session: $0.session.sessionID) }
  }

  public static func holds(_ work: CueWork, task: UUID?, session: String) -> Bool {
    switch work {
    case .task(let item): item.id == task
    case .session(let state): state.sessionID == session
    }
  }
  public var waiting: [Wait]
  public var replies: [Reply]
  public var held: Set<UUID> {
    Set(waiting.compactMap(\.task) + replies.compactMap(\.task))
  }

  public init(works: [CueWork], waiting: [Wait], replies: [Reply]) {
    self.works = works
    self.waiting = waiting
    self.replies = replies
  }

  public static let empty = CueTally(works: [], waiting: [], replies: [])
}

extension CueStore {
  public func cueTally() throws -> CueTally {
    let waiting = try cueWaiting()
    let replying = try sessionsAwaitingReply()
    let owners = try sessionOwners(replying.map(\.sessionID))
    let board = try cueBoard()
    return CueTally(
      works: CueBoard(tasks: board.tasks, sessions: try notEnding(board.sessions)).inProgress, waiting: waiting, replies: replying.map { CueTally.Reply(session: $0, task: owners[$0.sessionID]?.task.id) })
  }

  public func cueWaiting() throws -> [CueTally.Wait] {
    let sessions = try sessionsAskingYou()
    let owners = try sessionOwners(sessions.map(\.sessionID))
    return sessions.map { CueTally.Wait(session: $0, task: owners[$0.sessionID]?.task.id) }
  }

  public func sessionOwners(_ sessionIDs: [String]) throws -> [String: (task: Card, leaf: Card)] {
    guard !sessionIDs.isEmpty else { return [:] }
    let rows = try db.query(Self.sessionOwnerTops(where: "piSessionID IN (SELECT value FROM json_each(?1))"), [JSONColumn.encode(sessionIDs)]) { (session: $0.text(0), leaf: $0.uuid(1), task: $0.uuid(2)) }
    let cards = Dictionary(uniqueKeysWithValues: try select(
      Card.self, where: "id IN (SELECT value FROM json_each(?))", [Self.idList(rows.flatMap { [$0.leaf, $0.task] })]).map { ($0.id, $0) })
    return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
      guard let task = cards[row.task], let leaf = cards[row.leaf] else { return nil }
      return (row.session, (task: task, leaf: leaf))
    })
  }

  static func sessionOwnerRows(where condition: String) -> String {
    """
    SELECT sessionID, leaf FROM (
      SELECT piSessionID AS sessionID, id AS leaf,
        ROW_NUMBER() OVER (PARTITION BY piSessionID ORDER BY completedAt IS NULL DESC, startedAt DESC, id) AS rank
      FROM cards WHERE piSessionID IS NOT NULL AND \(taskOnBoard()) AND (\(condition)))
    WHERE rank = 1
    """
  }

  static func sessionOwnerTops(where condition: String) -> String {
    """
    WITH owner(sessionID, leaf) AS (\(sessionOwnerRows(where: condition)))
    SELECT o.sessionID, o.leaf, up.top FROM owner o JOIN (\(tops(of: "SELECT leaf FROM owner"))) up ON up.start = o.leaf
    """
  }
}
