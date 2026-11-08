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

  /// 在真正交给 Agent 前核对自动结束资格。明确 end 不经此方法授权，也不会被它拦住。
  public func permitsTaskSessionEnd(_ request: DeliveryRequest) throws -> Bool {
    guard request.mode == .known(.end), request.content != "end" else { return true }
    guard let reason = TaskSessionEnd(stored: request.content), let sessionID = request.target.ref,
      let session = try sessionState(sessionID), session.createdForTaskID == reason.createdForTaskID else { return false }
    return try taskSessionCanEnd(session)
  }

  /// 来源与可结束能力是不同事实；全局仍有使用者、在途消息或同任务下一步会接续时必须保留。
  func taskSessionCanEnd(_ session: PiSessionState) throws -> Bool {
    guard session.endsWithTask, let owner = session.createdForTaskID,
      let card = try find(Card.self, owner) else { return false }
    let topID = try card.parentID.map { try ancestors(of: $0).last ?? $0 } ?? owner
    guard try db.first(Self.usedElsewhere, [session.sessionID, topID], { _ in true }) == nil else { return false }
    guard let top = try find(Card.self, topID) else { return false }
    let open = try select(Card.self,
      where: "id IN (SELECT value FROM json_each(?)) AND \(Self.taskOpen)", [Self.idList(try leaves(of: top).map(\.id))], orderBy: "sortKey, id")
    let launching = try launchingLeaves(open.map(\.id))
    guard !open.contains(where: { $0.piSessionID == session.sessionID && !launching.contains($0.id) }) else { return false }
    if let next = open.first, next.id != top.id, next.piSessionID == nil, !launching.contains(next.id),
      try sendingLeaves([next.id]).isEmpty, try continuableSession(for: next.id, agent: nil, ignoringEndOf: session.sessionID)?.sessionID == session.sessionID { return false }
    // 解绑不代表完成原任务，也不授权借用者结束其尚未交付的工作。
    if open.contains(where: { $0.id == owner && $0.piSessionID == nil }), !launching.contains(owner) { return false }
    return true
  }
}
