import CueText
import Foundation

extension CueStore {
  public func upsertSession(_ session: IndexedSession, checkpoint: Data? = nil, host: String, transcript: SessionTranscript? = nil) throws {
    try upsertSessions([SessionUpsert(session: session, checkpoint: checkpoint, transcript: transcript)], host: host)
  }

  public func upsertSessions(_ batch: [SessionUpsert], host: String) throws {
    try write { try upsertSessionRows(batch, host: host) }
  }

  public func seedSession(_ session: IndexedSession, host: String) throws {
    try write {
      guard try find(IndexedSession.self, session.id) == nil else { return }
      try upsertSessionRows([SessionUpsert(session: session, checkpoint: nil, transcript: nil)], host: host)
    }
  }

  private func upsertSessionRows(_ batch: [SessionUpsert], host: String) throws {
    let assignments = IndexedSession.columns.dropFirst().map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
    let placeholders = (IndexedSession.columns + ["checkpoint"]).map { _ in "?" }.joined(separator: ", ")
    let bound = try boundDirectories()
    for item in batch {
      try writeSessionHistory(item.session, host: host, bound: bound)
      if let transcript = item.transcript { try applyTranscript(transcript) }
      try db.run(
        """
        INSERT INTO piSessions (\(IndexedSession.columns.joined(separator: ", ")), checkpoint) VALUES (\(placeholders))
        ON CONFLICT(id) DO UPDATE SET \(assignments),
          checkpoint = COALESCE(excluded.checkpoint, piSessions.checkpoint)
        """, item.session.bindings + [item.checkpoint])
    }
  }

  public func deliveryHistoryFiles(on host: String) throws -> Set<URL> {
    let unsettled = "r.hostID = ?1 AND r.status NOT IN ('\(DeliveryStatus.succeeded.rawValue)', '\(DeliveryStatus.failed.rawValue)')"
    return Set(try db.query(
      """
      SELECT path FROM piSessions p WHERE p.agent = '\(AgentKind.pi.rawValue)' AND p.id IN (
        SELECT r.targetRef FROM deliveryRequests r WHERE \(unsettled) AND r.mode = 'send'
        UNION
        SELECT s.sessionID FROM deliveryRequests r JOIN piSessionStates s ON s.launchToken = \(Self.launchToken("r"))
        WHERE \(unsettled) AND r.mode = 'start')
      """, [host]) { URL(filePath: $0.text(0)) })
  }

  @discardableResult
  public func retainSessions(paths: Set<String>, agent: AgentKind, host: String) throws -> Int {
    try write {
      let indexed = try db.query("SELECT id, path FROM piSessions WHERE agent = ?", [agent.rawValue]) { ($0.text(0), $0.text(1)) }
      let retained = agent == .pi ? Set(try deliveryHistoryFiles(on: host).map(\.path)) : []
      let stale = indexed.filter { !paths.contains($0.1) && !retained.contains($0.1) }
      for (id, _) in stale { try db.run("DELETE FROM piSessions WHERE id = ?", [id]) }
      try db.run(
        """
          DELETE FROM piSessionStates WHERE hostID = ? AND (state = ? OR state = ? AND hosted IS NULL) AND agent = ? AND sessionID NOT IN (SELECT id FROM piSessions)
          """,
        [host, WorkState.ended.rawValue, WorkState.interrupted.rawValue, agent.rawValue])
      let unrecorded = try select(
        IndexedSession.self, where: "NOT EXISTS (SELECT 1 FROM piSessionStates s WHERE s.sessionID = piSessions.id)")
      let bound = try boundDirectories()
      for session in unrecorded { try writeSessionHistory(session, host: host, bound: bound) }
      return stale.count
    }
  }

  public func deleteSessions(of agent: AgentKind, keepingHostedOn host: String) throws {
    try write {
      try db.run(
        "DELETE FROM piSessions WHERE agent = ? AND id NOT IN (\(Self.hostedSessionsSQL))", [agent.rawValue, host, agent.rawValue])
    }
  }

  public func hostedSessionIDs(of agent: AgentKind, host: String) throws -> Set<String> {
    Set(try db.query(Self.hostedSessionsSQL, [host, agent.rawValue]) { $0.text(0) })
  }

  private static let hostedSessionsSQL = "SELECT sessionID FROM piSessionStates WHERE hostID = ? AND agent = ? AND \(hostedOrLaunched)"

  static let hostedOrLaunched = "(hosted = 1 OR launchToken IS NOT NULL)"

  public func indexedSession(_ id: String) throws -> IndexedSession? { try find(IndexedSession.self, id) }

  private func writeSessionHistory(_ session: IndexedSession, host: String, bound: [BoundDirectory]) throws {
    let id = SessionState.recordID(sessionID: session.id)
    let cwd = URL(filePath: session.cwd, directoryHint: .isDirectory)
    let folder = Self.folderName(ofWorkingDirectory: session.cwd)
    let title = session.title.isEmpty ? (session.cwd.isEmpty ? "" : cwd.lastPathComponent) : session.title
    let projectID = session.cwd.isEmpty ? nil : Self.projectID(containing: cwd, in: bound)
    let now = Date.stamp
    let model = session.model.map { ModelOption(key: $0, name: "", thinkingLevels: []) }
    guard let existing = try find(SessionState.self, id) else {
      _ = try insert(SessionState(
        id: id, sessionID: session.id, hostID: host, title: title, projectID: projectID, state: .known(.ended), detail: nil,
        folder: folder, lastPrompt: nil, lastReply: nil, question: nil, notify: nil, stateSince: session.lastActivityAt,
        busySince: nil, createdAt: now, modifiedAt: now, model: model, thinking: session.thinking.map(Open.init(rawValue:)),
        agent: .known(session.agent)))
      return
    }
    guard existing.state == .known(.ended) else { return }
    let sameModel = "(json_extract(model, '$.provider') IS ?8 AND json_extract(model, '$.id') IS ?9)"
    try db.run(
      """
      UPDATE piSessionStates SET title = ?1, folder = ?2, projectID = ?3, stateSince = MAX(stateSince, ?4), modifiedAt = ?5,
        model = CASE WHEN ?7 IS NULL OR \(sameModel) THEN model ELSE ?7 END, thinking = COALESCE(?10, thinking)
      WHERE id = ?6 AND (title IS NOT ?1 OR folder IS NOT ?2 OR projectID IS NOT ?3 OR stateSince < ?4
        OR (?7 IS NOT NULL AND NOT \(sameModel)) OR (?10 IS NOT NULL AND thinking IS NOT ?10))
      """,
      [title, folder, projectID, session.lastActivityAt, now, id, model.map(JSONColumn.encode), session.model?.provider, session.model?.id, session.thinking])
  }
}

extension CueStore {
  public func checkpoint(of session: String) throws -> Data? {
    try db.first("SELECT checkpoint FROM piSessions WHERE id = ?", [session]) { $0.blobOrNil(0) } ?? nil
  }

  public func indexStarts() throws -> [String: IndexedSessionStart] {
    let rows = try db.query(
      "SELECT path, id, checkpoint, EXISTS (SELECT 1 FROM piMessages m WHERE m.sessionID = s.id) FROM piSessions s"
    ) { ($0.text(0), IndexedSessionStart(id: $0.text(1), checkpoint: $0.blobOrNil(2), hasMessages: $0.int(3) != 0)) }
    return Dictionary(rows, uniquingKeysWith: { first, _ in first })
  }

  public func indexedSessions() throws -> [IndexedSession] {
    try select(IndexedSession.self, orderBy: "lastActivityAt DESC, id")
  }
}
