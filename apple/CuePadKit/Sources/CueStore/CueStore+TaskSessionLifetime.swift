import Foundation

extension CueStore {
  /// 创建时转存来源，之后不再依赖投送或发送历史；恢复、摘要与纯关联不能改写它。
  func recordSessionCreationInTransaction(_ sessionID: String, from request: DeliveryRequest) throws {
    guard request.mode == .known(.start), let launch = request.launch, let owner = launch.createdForTaskID else { return }
    try db.run(
      "UPDATE piSessionStates SET createdForTaskID = ?, modifiedAt = ? WHERE sessionID = ? AND launchToken = ? AND createdForTaskID IS NULL",
      [owner, Date.stamp, sessionID, launch.token])
  }

  /// 你对它说话、翻回绑着它的已完成任务之后，为之开它的与绑着它的都不在看板上没做完：你在恢复使用一个收尾过的会话，从此不随任务结束（`restoredAt`）。
  /// 为之开它的那件还没同步到时不记：看不出它收没收尾。必须在写事务内调用。
  func noteRestored(_ sessionID: String) throws {
    let now = Date.stamp
    try db.run(
      """
      UPDATE piSessionStates SET restoredAt = ?1, modifiedAt = ?1
      WHERE sessionID = ?2 AND restoredAt IS NULL AND createdForTaskID IN (SELECT id FROM cards)
        AND NOT EXISTS (SELECT 1 FROM cards c WHERE (c.id = piSessionStates.createdForTaskID OR c.piSessionID = ?2) AND \(Self.taskOpen))
      """, [now, sessionID])
  }

  /// 与投送转入 executing 同事务复核；受理后新借用与发送由同一投送状态拒绝。明确 end 不受此规则限制。
  func permitsTaskSessionEnd(_ request: DeliveryRequest) throws -> Bool {
    guard request.mode == .known(.end), request.end != .explicit else { return true }
    guard case .task(let owner) = request.end, let sessionID = request.target.ref,
      let session = try sessionState(sessionID), session.createdForTaskID == owner else { return false }
    return try taskSessionCanEnd(session)
  }

  /// 自动结束一经领取就不可逆（领取那一刻复核过没人在用），未知结果也不能假定尚未交出：这之后不再借用、不再发话。
  /// 还没领取的自动结束不挡：这时说话正是"还有人在用"，领取时的复核会作废它。点名的结束不挡：之后说话会恢复会话。
  func requireSessionAvailable(_ sessionID: String) throws {
    let ending = try db.first("""
      SELECT 1 FROM deliveryRequests AS r WHERE r.targetRef = ? AND \(DeliveryRequest.endingSQL("r")) AND NOT \(DeliveryRequest.explicitEndSQL("r"))
        AND r.status IN (\(DeliveryStatus.claimedSQL))
      """, [sessionID]) { _ in true } ?? false
    if ending { throw CueStoreError.sessionEnding }
  }

  /// 为任务开的会话能不能随任务结束，唯一的规则：发起结束（`endUnusedSessions`）与执行的 Mac 受理结束（`permitsTaskSessionEnd`）都只问它，
  /// 不论是哪件事的收尾带出来的。来源与可结束能力是不同事实：纯关联、来源未知的不结束。
  /// 留着的：有人在用（`sessionInUse`）；绑过它的各件事与为之开它的那件里，下一步还没开工、也没在往别处交，照 `handOffPlan` 默认会接着用它；
  /// 为之开它的那一步还在看板上却没绑着会话（解绑不代表做完，借用者不替它收尾）。
  func taskSessionCanEnd(_ session: SessionState) throws -> Bool {
    guard session.endsWithTask, let owner = session.createdForTaskID, try find(Card.self, owner) != nil else { return false }
    guard try !sessionInUse(session.sessionID) else { return false }
    let bound = try db.query("SELECT id FROM cards WHERE piSessionID = ? AND deletedAt IS NULL", [session.sessionID]) { $0.uuid(0) }
    // 上级还没同步到：这件事的下一步是谁还不知道，先留着；上级到了（插入算一次收尾复核）再看
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

  /// 你完成 `task`（连同它下面的）之后该歇下的会话，完成前问是预告（确认框照它说）、完成后问是照做（App 逐个点名结束）。
  /// 一条规则：这件事（顶层）再没有没做完的步骤，它里面绑着的会话就歇下——不问是不是为它开的；别的没做完的事还绑着的、有话正送进去的、已有结束在路上的不动。
  /// 与自动结束（`taskSessionCanEnd`，Cue 的 done 与同步来的收尾）是两条路：那条只结束为任务开的，不替你做没点过的事；这条是你亲手点了完成。
  public func sessionsFreed(byCompleting task: UUID) throws -> [SessionState] {
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

  /// 做完的这一步绑着会话、而它那件事还有没做完的步骤：会话留给后面的步骤，完成的提示照此说。
  public func completedTaskKeepsSession(_ task: UUID) throws -> Bool {
    guard let card = try find(Card.self, task), card.piSessionID != nil, let top = try find(Card.self, try self.top(of: task)) else { return false }
    return try leaves(of: top).contains { $0.completedAt == nil }
  }

  /// 有人在用这个会话：在看板上、没在开新会话的叶子绑着它（哪件事的都算），或有话正送进去。Cue 点名收会话（`endIdleSession`）也只认它。
  func sessionInUse(_ sessionID: String) throws -> Bool {
    let open = try db.query("SELECT id FROM cards WHERE piSessionID = ? AND \(Self.taskOpen)", [sessionID]) { $0.uuid(0) }
    if try open.count > launchingLeaves(open).count { return true }
    return try db.first(
      "SELECT 1 FROM deliveryRequests WHERE targetRef = ? AND mode IN (\(sqlList(DeliveryMode.toSession))) AND status IN (\(DeliveryStatus.openSQL))",
      [sessionID]) { _ in true } ?? false
  }
}
