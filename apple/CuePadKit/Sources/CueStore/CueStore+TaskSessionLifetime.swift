import Foundation

extension CueStore {
  func recordSessionCreationInTransaction(_ sessionID: String, from request: DeliveryRequest) throws {
    guard request.mode == .known(.start), let launch = request.launch, let owner = launch.createdForTaskID else { return }
    try db.run(
      "UPDATE piSessionStates SET createdForTaskID = ?, modifiedAt = ? WHERE sessionID = ? AND launchToken = ? AND createdForTaskID IS NULL",
      [owner, Date.stamp, sessionID, launch.token])
  }

  func noteRestored(_ sessionID: String) throws {
    let now = Date.stamp
    try db.run(
      """
      UPDATE piSessionStates SET restoredAt = ?1, modifiedAt = ?1
      WHERE sessionID = ?2 AND restoredAt IS NULL AND createdForTaskID IN (SELECT id FROM cards)
        AND NOT EXISTS (SELECT 1 FROM cards c WHERE (c.id = piSessionStates.createdForTaskID OR c.piSessionID = ?2) AND \(Self.taskOpen))
      """, [now, sessionID])
  }

  func permitsTaskSessionEnd(_ request: DeliveryRequest) throws -> Bool {
    guard request.mode == .known(.end), request.end != .explicit else { return true }
    guard case .task(let owner) = request.end, let sessionID = request.target.ref,
      let session = try sessionState(sessionID), session.createdForTaskID == owner else { return false }
    return try taskSessionCanEnd(session)
  }

  func requireSessionAvailable(_ sessionID: String) throws {
    let ending = try db.first("""
      SELECT 1 FROM deliveryRequests AS r WHERE r.targetRef = ? AND \(DeliveryRequest.endingSQL("r")) AND NOT \(DeliveryRequest.explicitEndSQL("r"))
        AND r.status IN (\(DeliveryStatus.claimedSQL))
      """, [sessionID]) { _ in true } ?? false
    if ending { throw CueStoreError.sessionEnding }
  }

  func taskSessionCanEnd(_ session: SessionState) throws -> Bool {
    guard session.endsWithTask, let owner = session.createdForTaskID, try find(Card.self, owner) != nil else { return false }
    guard try !sessionInUse(session.sessionID) else { return false }
    let bound = try db.query("SELECT id FROM cards WHERE piSessionID = ? AND deletedAt IS NULL", [session.sessionID]) { $0.uuid(0) }
    let parents = try db.query(
      "SELECT parentID FROM cards WHERE id IN (SELECT value FROM json_each(?)) AND parentID IS NOT NULL", [Self.idList(bound + [owner])]) { $0.uuid(0) }
    guard try parents.allSatisfy({ try find(Card.self, $0) != nil }) else { return false }
    let ownerTop = try top(of: owner)
    for topID in Set(try bound.map(top(of:))).union([ownerTop]) {
      guard let top = try find(Card.self, topID) else { continue }
      let open = try select(Card.self,
        where: "id IN (SELECT value FROM json_each(?)) AND \(Self.taskOpen)", [Self.idList(try leaves(of: top).map(\.id))], orderBy: "sortKey, id")
      let launching = try launchingLeaves(open.map(\.id))
      if let next = open.first, next.id != top.id, next.piSessionID == nil, !launching.contains(next.id), try sendingLeaves([next.id]).isEmpty,
        try continuableSession(for: next.id, agent: nil, ignoringEndOf: session.sessionID)?.sessionID == session.sessionID { return false }
      if topID == ownerTop, open.contains(where: { $0.id == owner && $0.piSessionID == nil }), !launching.contains(owner) { return false }
    }
    return true
  }

  func sessionsFreed(byCompleting task: UUID) throws -> [SessionState] {
    guard let card = try find(Card.self, task), card.isTask, let top = try find(Card.self, try self.top(of: task)) else { return [] }
    let done = Set(try db.query("SELECT id FROM cards WHERE id IN (\(Self.subtree(from: "SELECT ?")))", [task]) { $0.uuid(0) })
    guard try leaves(of: top).allSatisfy({ $0.completedAt != nil || done.contains($0.id) }) else { return [] }
    let sessions = try db.query(
      """
      SELECT DISTINCT piSessionID FROM cards WHERE piSessionID IS NOT NULL AND id IN (\(Self.subtree(from: "SELECT ?1")))
        AND NOT EXISTS (SELECT 1 FROM cards c WHERE c.piSessionID = cards.piSessionID AND \(Self.taskOpen) AND c.id NOT IN (\(Self.subtree(from: "SELECT ?1"))))
        AND NOT EXISTS (
          SELECT 1 FROM deliveryRequests r WHERE r.targetRef = cards.piSessionID
            AND (\(DeliveryRequest.endingSQL("r")) OR (r.mode IN (\(sqlList(DeliveryMode.toSession))) AND r.status IN (\(DeliveryStatus.openSQL)))))
      """, [top.id]) { $0.text(0) }
    return try sessionStates(sessions).values.filter(\.canEnd).sorted { $0.sessionID < $1.sessionID }
  }

  public func sessionsKept(afterCompleting task: UUID) throws -> [SessionState] {
    let sessions = try db.query(
      """
      SELECT DISTINCT piSessionID FROM cards WHERE piSessionID IS NOT NULL AND id IN (\(Self.subtree(from: "SELECT ?")))
        AND NOT EXISTS (SELECT 1 FROM deliveryRequests r WHERE r.targetRef = cards.piSessionID AND \(DeliveryRequest.endingSQL("r")))
      """, [task]) { $0.text(0) }
    return try sessionStates(sessions).values.filter(\.canEnd)
  }

  func sessionInUse(_ sessionID: String) throws -> Bool {
    let open = try db.query("SELECT id FROM cards WHERE piSessionID = ? AND \(Self.taskOpen)", [sessionID]) { $0.uuid(0) }
    if try open.count > launchingLeaves(open).count { return true }
    return try db.first(
      "SELECT 1 FROM deliveryRequests WHERE targetRef = ? AND mode IN (\(sqlList(DeliveryMode.toSession))) AND status IN (\(DeliveryStatus.openSQL))",
      [sessionID]) { _ in true } ?? false
  }
}
