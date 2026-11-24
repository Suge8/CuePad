import CueText
import Foundation

extension CueStore {
  public func sessionPage(_ query: SessionQuery) throws -> SessionListPage {
    let (condition, arguments) = try Self.condition(query)
    // 只有一种状态的范围里"已结束的排后面"是常量，留着它 SQLite 就不走按状态的索引、把整个范围排一遍（真实库已结束的一页 17 万步对 3 千步）
    let endedLast = query.scope == .all || query.scope == .current ? "state = '\(WorkState.ended.rawValue)', " : ""
    let states = try select(
      SessionState.self, where: condition, arguments, orderBy: "\(endedLast)stateSince DESC, id", limit: query.limit, offset: query.offset)
    let total = try db.first("SELECT count(*) FROM piSessionStates WHERE \(condition)", arguments) { Int($0.int(0)) } ?? 0
    return SessionListPage(items: try listItems(states), total: total)
  }

  private static let home = """
    CASE WHEN projectID IN (SELECT id FROM projects WHERE deletedAt IS NULL) THEN projectID ELSE '\(Project.defaultID.uuidString.lowercased())' END
    """

  private static func condition(_ query: SessionQuery) throws -> (String, [any SQLBindable]) {
    var conditions: [String] = []
    var arguments: [any SQLBindable] = []
    switch query.scope {
    case .live: conditions.append(WorkState.outsideSQL([.ended]))
    case .ended: conditions.append("state = '\(WorkState.ended.rawValue)'")
    case .all: break
    case .current:
      conditions.append(
        """
        (\(WorkState.outsideSQL([.ended])) OR sessionID IN (SELECT targetRef FROM deliveryRequests
          WHERE targetKind = '\(SendTargetKind.piSession.rawValue)' AND mode IN (\(sqlList(DeliveryMode.toSession)))))
        """)
    }
    if let text = query.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
      let pattern = "%" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
        .replacingOccurrences(of: "_", with: "\\_") + "%"
      let named = Project.nameMatch(text, stored: "name LIKE ? ESCAPE '\\'")
      conditions.append(
        """
        (title LIKE ? ESCAPE '\\' OR folder LIKE ? ESCAPE '\\' OR lastPrompt LIKE ? ESCAPE '\\'
          OR \(home) IN (SELECT id FROM projects WHERE \(named.sql)))
        """)
      arguments += [pattern, pattern, pattern, pattern] + named.arguments
    }
    if let project = query.project {
      conditions.append(project == Project.defaultID ? "\(home) = ?" : "projectID = ?")
      arguments.append(project)
    }
    if let token = query.launchToken {
      conditions.append("launchToken = ?")
      arguments.append(token)
    }
    if let id = query.id {
      conditions.append("id = ?")
      arguments.append(id)
    }
    if !query.excluding.isEmpty {
      conditions.append("sessionID NOT IN (SELECT value FROM json_each(?))")
      arguments.append(String(decoding: try JSONEncoder().encode(query.excluding), as: UTF8.self))
    }
    if let pinned = query.pinned {
      conditions.append("sessionID \(pinned ? "IN" : "NOT IN") (\(pinnedSessions))")
    }
    return (conditions.isEmpty ? "1" : conditions.joined(separator: " AND "), arguments)
  }

  public func sessionItems(sessionIDs: [String]) throws -> [String: SessionListItem] {
    guard !sessionIDs.isEmpty else { return [:] }
    let ids = String(decoding: try JSONEncoder().encode(sessionIDs), as: UTF8.self)
    let states = try select(SessionState.self, where: "sessionID IN (SELECT value FROM json_each(?))", [ids])
    return Dictionary(try listItems(states).map { ($0.state.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
  }

  public func sessionCount() throws -> Int {
    try db.first("SELECT count(*) FROM piSessionStates") { Int($0.int(0)) } ?? 0
  }

  private func listItems(_ states: [SessionState]) throws -> [SessionListItem] {
    let ids = states.map(\.sessionID)
    let projects = Dictionary(uniqueKeysWithValues: try self.projects().map { ($0.id, $0) })
    let deliveries = try latestDeliveries(to: ids)
    let renames = try latestRenames(to: ids)
    let answers = try latestDeliveries(to: ids, modes: [.answer])
    let unsettled = try unsettledTalk(to: ids)
    let tasks = try sessionOwners(ids).mapValues { SessionTask(id: $0.task.id, isPinned: $0.task.isPinned, title: CueSummary.title(of: $0.leaf.body), isDone: $0.leaf.completedAt != nil) }
    return states.map {
      SessionListItem(
        state: $0, project: $0.projectID.flatMap { projects[$0] }, delivery: deliveries[$0.sessionID], rename: renames[$0.sessionID],
        answer: answers[$0.sessionID], unsettled: unsettled[$0.sessionID] ?? [], task: tasks[$0.sessionID])
    }
  }

  private static let pinnedSessions = """
    SELECT o.sessionID FROM (\(sessionOwnerTops(where: "1"))) o JOIN cards t ON t.id = o.top WHERE t.isPinned = 1
    """

  func sessionsAskingYou() throws -> [SessionState] {
    let cue = try cueDuty()
    let waiting = WorkState.waitingForUser.rawValue
    let asking = try narrow(.piSessionStates, column: "state", candidates: "state = '\(waiting)'", to: { $0 == waiting }) { rows in
      try sessions(rows).filter { $0.asksYou(cue) }
    }
    return try notEnding(asking)
  }

  func notEnding(_ sessions: [SessionState]) throws -> [SessionState] {
    guard !sessions.isEmpty else { return sessions }
    let ending = Set(try db.query(
      "SELECT r.targetRef FROM deliveryRequests AS r WHERE r.targetRef IN (SELECT value FROM json_each(?)) AND \(DeliveryRequest.endingSQL("r"))",
      [JSONColumn.encode(sessions.map(\.sessionID))]) { $0.text(0) })
    return sessions.filter { !ending.contains($0.sessionID) }
  }

  public func sessionsAwaitingReply() throws -> [SessionState] {
    guard let cue = try cueDuty() else { return [] }
    let resting: [WorkState] = [.settled, .error]
    let handed = cue.tiers.filter { $0.value != .yours }.keys
    let candidates = "state IN (\(sqlList(resting))) AND (sessionID IN (SELECT value FROM json_each(?)) OR sessionID NOT IN (SELECT value FROM json_each(?)))"
    let left = try narrow(
      .piSessionStates, column: "state", candidates: candidates, arguments: [JSONColumn.encode(cue.left.map(\.sessionID)), JSONColumn.encode(Array(handed))],
      to: { WorkState(rawValue: $0).map(resting.contains) == true }
    ) { rows in try sessions(rows).filter { $0.awaitsReply(cue) } }
    let said = try latestDeliveries(to: left.map(\.sessionID))
    return try notEnding(left).filter { session in
      guard let request = said[session.sessionID] else { return true }
      return request.createdAt <= session.stateSince || request.status == .known(.failed)
    }
    .sorted { ($0.stateSince, $0.sessionID) < ($1.stateSince, $1.sessionID) }
  }

  private func sessions(_ rows: Set<Int64>) throws -> [SessionState] {
    rows.isEmpty ? [] : try select(SessionState.self, where: "rowid IN (SELECT value FROM json_each(?))", [JSONColumn.encode(rows.sorted())])
  }

  func latestRenames(to sessionIDs: [String]) throws -> [String: DeliveryRequest] {
    guard !sessionIDs.isEmpty else { return [:] }
    let configs = try select(
      DeliveryRequest.self,
      where: "targetKind = '\(SendTargetKind.piSession.rawValue)' AND mode = '\(DeliveryMode.config.rawValue)' AND targetRef IN (SELECT value FROM json_each(?))",
      [JSONColumn.encode(sessionIDs)], orderBy: "createdAt, rowid")
    return Dictionary(grouping: configs) { $0.target.ref ?? "" }.compactMapValues(DeliveryRequest.latestRename(in:))
  }

  func unsettledTalk(to sessionIDs: [String]) throws -> [String: [DeliveryRequest]] {
    guard !sessionIDs.isEmpty else { return [:] }
    let requests = try select(
      DeliveryRequest.self,
      where: """
        targetKind = '\(SendTargetKind.piSession.rawValue)' AND mode = '\(DeliveryMode.send.rawValue)'
          AND status IN ('\(DeliveryStatus.pending.rawValue)', '\(DeliveryStatus.preparing.rawValue)', '\(DeliveryStatus.failed.rawValue)') AND targetRef IN (SELECT value FROM json_each(?))
        """, [JSONColumn.encode(sessionIDs)], orderBy: "createdAt, rowid")
    return Dictionary(grouping: requests) { $0.target.ref ?? "" }
  }

  func latestDeliveries(to sessionIDs: [String], modes: Set<DeliveryMode> = DeliveryMode.toSession) throws -> [String: DeliveryRequest] {
    guard !sessionIDs.isEmpty else { return [:] }
    let requests = try select(
      DeliveryRequest.self,
      where: "targetKind = '\(SendTargetKind.piSession.rawValue)' AND mode IN (\(sqlList(modes))) AND targetRef IN (SELECT value FROM json_each(?))",
      [JSONColumn.encode(sessionIDs)], orderBy: "createdAt DESC, rowid DESC")
    var latest: [String: DeliveryRequest] = [:]
    for request in requests {
      if let ref = request.target.ref, latest[ref] == nil { latest[ref] = request }
    }
    return latest
  }

  public func endedSessions(on host: String, since: Date, limit: Int) throws -> [SessionState] {
    try select(
      SessionState.self, where: "state = ? AND hostID = ? AND stateSince >= ?", [WorkState.ended.rawValue, host, since],
      orderBy: "stateSince DESC, id", limit: limit)
  }

  public func lastModel(ofSession sessionID: String) throws -> ModelKey? {
    try find(SessionState.self, SessionState.recordID(sessionID: sessionID))?.model?.key
  }

  public func sessionFolders() throws -> [SessionFolder] { try folders(where: Self.hasFolder, []) }

  static let hasFolder = "folder IS NOT NULL AND folder != ''"

  private func folders(where condition: String, _ arguments: [any SQLBindable]) throws -> [SessionFolder] {
    try db.query(
      """
      SELECT hostID, folder, sessionID, projectID, count(*), max(stateSince), \(MacAgents.nameSQL(host: "piSessionStates.hostID"))
      FROM piSessionStates WHERE \(condition) GROUP BY hostID, folder ORDER BY max(stateSince) DESC, count(*) DESC, hostID, folder
      """, arguments
    ) {
      SessionFolder(
        hostID: $0.text(0), folder: $0.text(1), sessionID: $0.text(2), projectID: $0.uuidOrNil(3), count: Int($0.int(4)),
        macName: MacAgents.shownName($0.textOrNil(6)))
    }
  }
}
