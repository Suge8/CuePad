import CueText
import Foundation

/// `createdForTaskID` 持久保存会话的创建来源，纯关联（没有任务创建来源）不授权结束；`executing` 的会话拒绝本地借用；跨端后到的关联不撤回已发出的结束，可以指向历史。
/// 结束请求领取时固定一个请求 ID 集合，源端实际结束与这些请求的结果在同一个事务里写回；同步只合并同一条请求，不凭时间或 ended 的回声确认别的请求。
/// 重启后没有证据的会话保持“未知”；会话页与 Cue 可以明确结束它，这只覆盖受理那一刻已知的旧未知，不扩到之后的新请求。

extension CueStore {
  /// 算不算做完由 Cue 按证据自己定，不请你确认。还有没完成的子任务抛 `stepsRemaining`、什么都不改；否则完成它，结束没人再用的会话（`endUnusedSessions`，请求算 Cue 发起的）。顶层任务同时写一条给你的结果（`CueReport.text`）：你不认可就把它改回没做完，或直接告诉 Cue。结果上只挂 Cue 点名的图（`shots`），没点名就不挂；点名的不在发到手机的里抛 `shotMissing`、什么都不改。已完成的再做完一次只结束没人再用的会话（说话会恢复已结束的会话，答完就空着），状态与结果不再写。证据的条数与长短由调用方（Cue 的工具）把关。返回这条结果（子任务与已完成的为 nil）与结束请求。
  @discardableResult
  public func finishTask(_ task: UUID, evidence: [String], shots: [CueShot] = [], answeredRequests: [UUID]? = []) throws -> (report: CueMessage?, ended: [DeliveryRequest]) {
    try write {
      try checkStepsDone(task)
      try checkShots(shots)
      guard let card = try find(Card.self, task) else { throw CueStoreError.notFound }
      let finished = card.status != .done
      _ = try applyStatus(task, .done)
      let ended = try endUnusedSessions(of: task, cue: true)
      guard finished, card.parentID == nil else { return (nil, ended) }
      return (try insertCueMessage(.cue, shown: CueReport.text(task: card.heading, evidence: evidence), shots: shots, task: task, answeredRequests: answeredRequests), ended)
    }
  }

  private func checkStepsDone(_ task: UUID) throws {
    let card = try requireTask(task)
    let remaining = try leaves(of: card).filter { $0.id != task && $0.completedAt == nil }.count
    guard remaining == 0 else { throw CueStoreError.stepsRemaining(remaining) }
  }

  /// 已完成的什么都不改，所以界面手里的副本过时（别的设备刚做完）、或延迟提交时它已被做完，都不会把它翻回去。读与改在一个事务里：两次 `await` 之间也可能有同步来的改动插进来。返回新状态。
  @discardableResult
  public func completeTask(_ id: UUID) throws -> TaskStatus {
    try write {
      guard let card = try find(Card.self, id) else { throw CueStoreError.notFound }
      guard let current = card.status else { throw CueStoreError.notATask }
      guard current != .done else { return .done }
      return try applyStatus(id, .done)
    }
  }

  /// 撤销一次完成：它还是那一次做完的（完成时刻是 `time`）、没归档没删才撤，连同那一次连带做完的下级（其间单独归档了的不动）、那一次才带着开始的上级；否则抛 `changedSinceUndo`。
  /// 那一次结束的会话、停掉的定时不恢复（同 `reopen`：再对它说话就在后台恢复）。
  public func uncompleteTask(_ id: UUID, completedAt time: Date) throws {
    try write {
      guard let card = try find(Card.self, id), card.completedAt == time, card.archivedAt == nil, card.deletedAt == nil else {
        throw CueStoreError.changedSinceUndo
      }
      let now = Date.stamp
      try db.run(
        "UPDATE cards SET completedAt = NULL, modifiedAt = ?1 WHERE id IN (\(Self.subtree(from: "SELECT ?2"))) AND completedAt = ?3 AND archivedAt IS NULL",
        [now, id, time])
      // 完成时带着开始的上级（`applyStatus` 用同一个时刻记的）：下面没有别的开始了，就回到待办
      try db.run(
        "UPDATE cards SET startedAt = NULL, modifiedAt = ?1 WHERE id IN (SELECT value FROM json_each(?2)) AND startedAt = ?3 AND completedAt IS NULL",
        [now, Self.idList(try ancestors(of: id)), time])
    }
  }

  public func reopenTask(_ id: UUID) throws {
    try write { try reopen([id]) }
  }

  /// 你对会话说了话：绑着它的已完成任务回到进行中（绑着会话就是开始过，不回待办）。写下这句话时（`insertDelivery`）与执行的 Mac 领取它时（`claimDelivery`）各一次：
  /// 写的那台设备可能还没同步到完成，领取时带 `before`（这句话写下的时刻）只认在那之前做完的；话还在路上时你才点的完成不翻回。必须在写事务内调用。
  func reopenTasks(spokenToIn session: String, before: Date? = nil) throws {
    let done = try db.query(
      "SELECT id FROM cards WHERE piSessionID = ?1 AND completedAt IS NOT NULL AND (?2 IS NULL OR completedAt < ?2) AND \(Self.cardVisible)",
      [session, before]) { $0.uuid(0) }
    try reopen(done)
    let now = Date.stamp
    for task in done { try beginTask(task, at: now) }
  }

  /// 不再算做完，只在这里写。`tasks` 连同各自已完成的上级清掉完成时间：开始过的回到进行中，没开始过的回到待办；在归档里的，整件连同下级取回。你对它的会话说话也经这里（`insertDelivery`）。必须在写事务内调用。
  func reopen(_ tasks: [UUID]) throws {
    let chains = try tasks.map { [$0] + (try ancestors(of: $0)) }
    let done = try select(
      Card.self, where: "id IN (SELECT value FROM json_each(?)) AND todoAt IS NOT NULL AND completedAt IS NOT NULL",
      [Self.idList(chains.flatMap { $0 })])
    guard !done.isEmpty else { return }
    let reopened = Set(done.map(\.id))
    try db.run(
      "UPDATE cards SET completedAt = NULL, modifiedAt = ? WHERE id IN (SELECT value FROM json_each(?))", [Date.stamp, Self.idList(reopened)])
    try setArchived(chains.filter { !reopened.isDisjoint(with: $0) }.map { $0.last! }, at: nil)
  }

  /// 任务离开看板，或明确开工换会话时（纯关联不收尾），这件事里此刻绑着的、为它开的会话各看一遍（换下来的不看：它可能已结束后被你恢复起来另用），可以结束（`taskSessionCanEnd`）的请它所在的 Mac 结束。
  /// 不是为任务开的不结束，它随这件事从看板收起（`isLoose`），再有动静才回来；已结束的、记录还没到的不动。取回归档、撤销删除不重开：再对它说话就在后台恢复。
  /// `task` 可以已经归档或删掉（删掉的从它原来的上级往上找这件事）；灵感不管。必须在写事务内调用。
  @discardableResult
  func endUnusedSessions(of task: UUID, cue: Bool) throws -> [DeliveryRequest] {
    guard let card = try find(Card.self, task), card.isTask else { return [] }
    let sessions = try db.query(
      """
      SELECT piSessionID FROM cards WHERE piSessionID IS NOT NULL AND (id = ?1 OR id IN (\(Self.subtree(from: "SELECT ?2"))))
      UNION SELECT sessionID FROM piSessionStates WHERE createdForTaskID IN (\(Self.subtree(from: "SELECT ?2", includingDeleted: true)))
      """, [task, try top(of: task)]
    ) { $0.text(0) }
    var ended: [DeliveryRequest] = []
    for sessionID in sessions {
      guard let state = try sessionState(sessionID), try taskSessionCanEnd(state), let owner = state.createdForTaskID else { continue }
      ended.append(try requestControl(.end, of: SendTarget(kind: .piSession, name: state.title, ref: sessionID), on: state.hostID, cue: cue,
        content: DeliveryRequest.EndKind.task(createdFor: owner).stored))
    }
    return ended
  }

  public func workingLeaf(of task: UUID) throws -> Card {
    try requireTask(task)
    guard let leaf = try find(Card.self, try homeLeaf(task)) else { throw CueStoreError.notFound }
    return leaf
  }

  public func topTask(of task: UUID) throws -> UUID {
    try requireTask(task)
    return try top(of: task)
  }

  func requireLeaf(_ leaf: UUID) throws -> Card {
    let card = try requireTask(leaf)
    guard try homeLeaf(leaf) == leaf else { throw CueStoreError.notALeaf }
    return card
  }

  /// 不在库里或在回收站抛 `notFound`，不是任务抛 `notATask`。
  @discardableResult
  private func requireTask(_ id: UUID) throws -> Card {
    guard let card = try find(Card.self, id), card.deletedAt == nil else { throw CueStoreError.notFound }
    guard card.isTask else { throw CueStoreError.notATask }
    return card
  }

  func leaves(of task: Card) throws -> [Card] {
    let steps = try select(Card.self, where: "parentID = ? AND todoAt IS NOT NULL AND deletedAt IS NULL", [task.id], orderBy: "sortKey, id")
    return steps.isEmpty ? [task] : steps
  }
}
