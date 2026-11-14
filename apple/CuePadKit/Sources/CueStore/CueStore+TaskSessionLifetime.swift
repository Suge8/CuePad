import Foundation

/// 自动收尾请求携带创建来源，执行时重新核对；用户明确 end 的正文仍为 end，不受自动收尾规则限制。
struct TaskSessionEnd: StoredJSON {
  let createdForTaskID: UUID
}

extension CueStore {
  /// 创建时转存来源，之后不再依赖投送或发送历史；恢复、摘要与纯关联不能改写它。
  func recordSessionCreationInTransaction(_ sessionID: String, from request: DeliveryRequest) throws {
    guard request.mode == .known(.start), let launch = request.launch, let owner = launch.createdForTaskID else { return }
    try db.run(
      "UPDATE piSessionStates SET createdForTaskID = ?, modifiedAt = ? WHERE sessionID = ? AND launchToken = ? AND createdForTaskID IS NULL",
      [owner, Date.stamp, sessionID, launch.token])
  }

  /// 与投送转入 executing 同事务复核；受理后新借用与发送由同一投送状态拒绝。明确 end 不受此规则限制。
  func permitsTaskSessionEnd(_ request: DeliveryRequest) throws -> Bool {
    guard request.mode == .known(.end), request.content != "end" else { return true }
    guard let reason = TaskSessionEnd(stored: request.content), let sessionID = request.target.ref,
      let session = try sessionState(sessionID), session.createdForTaskID == reason.createdForTaskID else { return false }
    return try taskSessionCanEnd(session)
  }

  /// executing 是自动结束的不可逆受理点；未知结果也不能假定尚未交出。只读既有投送状态，不另存结束标志。
  func requireSessionAvailable(_ sessionID: String) throws {
    let ending = try db.first("""
      SELECT 1 FROM deliveryRequests WHERE targetRef = ? AND mode = 'end' AND content != 'end'
        AND (status IN ('executing', 'confirming', 'unconfirmed') OR (status = 'pending' AND handledBy IS NOT NULL))
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

  /// 有人在用这个会话：在看板上、没在开新会话的叶子绑着它（哪件事的都算），或有话正送进去。Cue 点名收会话（`endIdleSession`）也只认它。
  func sessionInUse(_ sessionID: String) throws -> Bool {
    let open = try db.query("SELECT id FROM cards WHERE piSessionID = ? AND \(Self.taskOpen)", [sessionID]) { $0.uuid(0) }
    if try open.count > launchingLeaves(open).count { return true }
    return try db.first(
      "SELECT 1 FROM deliveryRequests WHERE targetRef = ? AND mode IN (\(sqlList(DeliveryMode.toSession))) AND status IN (\(DeliveryStatus.openSQL))",
      [sessionID]) { _ in true } ?? false
  }
}
