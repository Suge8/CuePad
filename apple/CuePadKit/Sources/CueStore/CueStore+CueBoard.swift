import CueText
import Foundation

extension CueStore {
  public func cueBoardActive() throws -> Bool {
    try db.first("SELECT 1 FROM piSessionStates WHERE \(Self.isLoose("piSessionStates")) LIMIT 1") { _ in true } != nil
      || boardItems(try topTasks(where: Self.onBoard)).contains(where: \.isActive)
  }

  public func cueBoard() throws -> CueBoard {
    CueBoard(
      tasks: try boardItems(try topTasks(where: Self.onBoard)),
      sessions: try select(SessionState.self, where: Self.isLoose("piSessionStates"), orderBy: "stateSince DESC, id"))
  }

  public func cueRecentlyDone(limit: Int) throws -> [(task: Card, session: SessionState)] {
    try topTasks(where: "t.completedAt IS NOT NULL AND \(Self.hasSession)", orderBy: Self.recentlyDone, limit: limit)
      .compactMap { task in try latestSession(of: task.id).map { (task, $0) } }
  }

  static func isLoose(_ alias: String) -> String {
    """
    \(WorkState.outsideSQL([.ended], column: "\(alias).state"))
      AND NOT EXISTS (SELECT 1 FROM cards c WHERE \(usedSession("c", "\(alias).sessionID")) AND \(taskOpen))
      AND NOT EXISTS (
        SELECT 1 FROM cards c WHERE c.piSessionID = \(alias).sessionID AND \(taskDoneOnBoard) AND c.completedAt >= \(alias).stateSince)
    """
  }

  public func boardItems(_ tasks: [Card]) throws -> [CueBoardItem] {
    guard !tasks.isEmpty else { return [] }
    let links = try CardLinks(db, around: tasks.map(\.id))
    let homes = try cards(Set(tasks.map { links.home(of: $0.id) }))
    let lastDone = try lastCompletedSteps(of: tasks.filter { task in homes[links.home(of: task.id)].map { $0.id != task.id && $0.completedAt != nil } ?? false })
    let steps = Dictionary(grouping: try select(
      Card.self, where: "parentID IN (SELECT value FROM json_each(?)) AND todoAt IS NOT NULL AND deletedAt IS NULL AND completedAt IS NULL",
      [Self.idList(tasks.map(\.id))], orderBy: "sortKey, id"
    ), by: { $0.parentID! })
    let fallback = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, lastDone[$0.id] ?? homes[links.home(of: $0.id)] ?? $0) })
    let candidates = tasks.map { task in (steps[task.id] ?? []) + [fallback[task.id]!] }
    let all = candidates.flatMap { $0 }
    let sessions = try sessionStates(all.compactMap(\.piSessionID))
    let progress = try subtaskProgress(of: tasks.map(\.id))
    let handoffs = try handoffRequests(for: all.map(\.id))
    return zip(tasks, candidates).map { task, candidates in
      let leaves = candidates.map { leaf in
        let session = leaf.piSessionID.flatMap { sessions[$0] }
        return CueBoardLeaf(
          leaf: leaf, session: session, handoffs: (handoffs[leaf.id] ?? []).filter { leaf.piSessionID == nil || $0.mode == .known(.start) },
          since: session?.stateSince ?? leaf.startedAt ?? task.startedAt ?? task.todoAt ?? task.createdAt, at: .always(at: timing.now()))
      }
      let open = leaves.dropLast().filter(\.isActive)
      return CueBoardItem(task: task, progress: progress[task.id], leaves: open.isEmpty ? [leaves.last!] : Array(open))
    }
  }

  private func lastCompletedSteps(of tasks: [Card]) throws -> [UUID: Card] {
    guard !tasks.isEmpty else { return [:] }
    let steps = try select(
      Card.self, where: "parentID IN (SELECT value FROM json_each(?)) AND todoAt IS NOT NULL AND deletedAt IS NULL AND completedAt IS NOT NULL",
      [Self.idList(tasks.map(\.id))], orderBy: "completedAt, sortKey, id")
    return Dictionary(steps.compactMap { step in step.parentID.map { ($0, step) } }, uniquingKeysWith: { _, later in later })
  }

  private static let onBoard = "t.completedAt IS NULL AND t.archivedAt IS NULL"

  static let hasSession = """
    EXISTS (SELECT 1 FROM cards l WHERE (l.id = t.id OR l.parentID = t.id) AND l.todoAt IS NOT NULL AND l.deletedAt IS NULL AND l.piSessionID IS NOT NULL)
    """

  public func cueTaskDetail(_ task: UUID, rounds: Int = 3) throws -> CueTaskDetail {
    let top = try topTask(of: task)
    guard let card = try find(Card.self, top) else { throw CueStoreError.notFound }
    let leaves = try leaves(of: card)
    let sessions = try sessionStates(leaves.compactMap(\.piSessionID))
    let handoffs = try handoffRequests(for: leaves.filter { $0.piSessionID == nil }.map(\.id))
    let details = try leaves.map { leaf in
      CueLeafDetail(
        leaf: leaf, session: try leaf.piSessionID.flatMap { sessions[$0] }.map { try sessionDetail($0, rounds: rounds) },
        handoffs: handoffs[leaf.id] ?? [])
    }
    return CueTaskDetail(task: card, progress: try subtaskProgress(of: [top])[top], leaves: details)
  }

  public func cueSessionDetail(_ sessionID: String, rounds: Int = 3) throws -> CueSessionDetail? {
    try sessionState(sessionID).map { try sessionDetail($0, rounds: rounds) }
  }

  private func sessionDetail(_ session: SessionState, rounds: Int) throws -> CueSessionDetail {
    let recent = try select(
      ChatMessage.self, where: "sessionID = ? AND role IN ('\(ChatRole.user.rawValue)', '\(ChatRole.pi.rawValue)')", [session.sessionID],
      orderBy: "seq DESC, id DESC", limit: rounds * 2
    ).reversed()
    let before = try recent.first.map { first in
      try select(
        ChatMessage.self, where: "sessionID = ? AND role = '\(ChatRole.user.rawValue)' AND deliveryID IS NOT NULL AND seq < ?", [session.sessionID, first.seq],
        orderBy: "seq, id")
    } ?? []
    let cueSent = try cueSentDeliveries(among: (recent + before).compactMap(\.deliveryID))
    return CueSessionDetail(
      session: session, recent: Array(recent), cueSent: cueSent, earlier: before.filter { $0.saidByCue(cueSent) })
  }

  public func sessions(matching ref: String) throws -> [SessionState] {
    let key = ref.trimmingCharacters(in: .whitespaces)
    let byID = try select(
      SessionState.self, where: "sessionID = ?1 OR (length(?1) >= 4 AND sessionID >= ?1 AND sessionID < ?1 || '~')", [key],
      orderBy: "stateSince DESC, id")
    if !byID.isEmpty { return byID }
    return try select(SessionState.self, where: "title = ? COLLATE NOCASE", [key], orderBy: "stateSince DESC, id")
  }


  public func deliverables(of task: UUID) throws -> [PreviewItem] {
    try db.query(
      """
      WITH used(session) AS (\(Self.sessionsUsed(where: "todoAt IS NOT NULL AND id IN (\(Self.subtree(from: "SELECT ?1")))")))
      SELECT DISTINCT \(PreviewItem.columns.map { "p.\($0)" }.joined(separator: ", "))
      FROM previews p JOIN used u ON u.session = p.sessionID JOIN cards t ON t.id = ?1
      WHERE p.createdAt >= COALESCE(t.startedAt, t.todoAt)
      ORDER BY p.createdAt, p.id
      """, [task]
    ) { PreviewItem(row: $0) }
  }

  func topTasks(
    where condition: String, _ arguments: [any SQLBindable] = [], orderBy: String? = nil, limit: Int? = nil
  ) throws -> [Card] {
    try db.query(
      """
      SELECT \(Card.selection(as: "t")) FROM cards t LEFT JOIN projects p ON p.id = t.projectID
      WHERE t.parentID IS NULL AND t.todoAt IS NOT NULL AND t.deletedAt IS NULL AND (p.id IS NULL OR p.deletedAt IS NULL)
        AND \(condition)
      ORDER BY \(orderBy ?? "\(Self.taskProjectOrder), t.sortKey, t.id") LIMIT ?
      """, arguments + [limit ?? -1]
    ) { Card(row: $0) }
  }

  private func cards(_ ids: Set<UUID>) throws -> [UUID: Card] {
    Dictionary(
      uniqueKeysWithValues: try select(Card.self, where: "id IN (SELECT value FROM json_each(?))", [Self.idList(ids)]).map { ($0.id, $0) })
  }

  func sessionStates(_ sessionIDs: [String]) throws -> [String: SessionState] {
    guard !sessionIDs.isEmpty else { return [:] }
    return Dictionary(
      try select(SessionState.self, where: "sessionID IN (SELECT value FROM json_each(?))", [JSONColumn.encode(sessionIDs)]).map { ($0.sessionID, $0) },
      uniquingKeysWith: { first, _ in first })
  }
}
