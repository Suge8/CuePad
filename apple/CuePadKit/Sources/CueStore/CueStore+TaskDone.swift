import CueText
import Foundation

/// 一件事里没人再用的会话的去留（`CueStore.endUnused`）。
struct UnusedSessions {
  var ended: [DeliveryRequest] = []
  /// 终端里你自己开的会话没被结束。
  var terminalKept = false
}

extension CueStore {
  /// Cue 做完一件事：算不算做完由 Cue 按证据自己定，不请你确认。还有没完成的子任务抛 `stepsRemaining`、什么都不改；否则完成它，
  /// 结束没人再用的会话（`endUnusedSessions`，同你点圆圈 `completeTask`，请求算 Cue 发起的）。顶层任务同时写一条给你的结果
  /// （`CueReport.text`：标题加证据要点，关联任务）：做完告诉你；你不认可就把它改回没做完，或直接告诉 Cue。结果上只挂 Cue 点名的图（`shots`，
  /// 证明结论的最终成果、`CueShot.checked` 过的），没点名就不挂；这件事发到手机的其余文件仍在它的会话里。点名的不在发到手机的里抛 `shotMissing`、什么都不改。
  /// 已完成的再做完一次只结束没人再用的会话（说话会恢复已结束的会话，答完就空着），状态与结果不再写。
  /// 证据的条数与长短由调用方（Cue 的工具）把关。返回这条结果（子任务与已完成的为 nil）与结束请求。
  @discardableResult
  public func finishTask(_ task: UUID, evidence: [String], shots: [CueShot] = [], answeredRequests: [UUID]? = []) throws -> (report: CueMessage?, ended: [DeliveryRequest]) {
    try write {
      try checkStepsDone(task)
      try checkShots(shots)
      guard let card = try find(Card.self, task) else { throw CueStoreError.notFound }
      let finished = card.status != .done
      _ = try applyStatus(task, .done)
      let ended = try endUnusedSessions(of: task, cue: true).ended
      guard finished, card.parentID == nil else { return (nil, ended) }
      return (try insertCueMessage(.cue, shown: CueReport.text(task: card.heading, evidence: evidence), shots: shots, task: task, answeredRequests: answeredRequests), ended)
    }
  }

  /// 还有没完成的子任务就抛 `stepsRemaining`。
  private func checkStepsDone(_ task: UUID) throws {
    let card = try requireTask(task)
    let remaining = try leaves(of: card).filter { $0.id != task && $0.completedAt == nil }.count
    guard remaining == 0 else { throw CueStoreError.stepsRemaining(remaining) }
  }

  /// 把任务设为完成（连同结束做完了的会话，同 `finishTask`）：已完成的什么都不改，所以界面手里的副本过时（别的设备刚做完）、或延迟提交时它已被做完，
  /// 都不会把它翻回去。读与改在一个事务里：两次 `await` 之间也可能有同步来的改动插进来。返回新状态、结束请求，以及有没有终端里你自己开的会话没结束（`terminalKept`，提示里如实说）。
  /// 点掉已完成的圆圈是 `reopenTask`，不是再来一次它。
  @discardableResult
  public func completeTask(_ id: UUID) throws -> (status: TaskStatus, ended: [DeliveryRequest], terminalKept: Bool) {
    try write {
      guard let card = try find(Card.self, id) else { throw CueStoreError.notFound }
      guard let current = card.status else { throw CueStoreError.notATask }
      guard current != .done else { return (.done, [], false) }
      let status = try applyStatus(id, .done)
      let fate = try endUnusedSessions(of: id, cue: false)
      return (status, fate.ended, fate.terminalKept)
    }
  }

  /// Cue 的 edit reopen：把已完成的事改回没做完（`reopen`，同点掉圆圈）；没完成的什么都不改。
  public func reopenTask(_ id: UUID) throws {
    try write { try reopen([id]) }
  }

  /// 不再算做完，只在这里写：点掉已完成的圆圈与 Cue 的 edit reopen（都是 `reopenTask`）、给已完成的事加子任务（`createTask(_:under:)`）、
  /// 把完成的改成别的状态（`applyStatus`）。`tasks` 连同各自已完成的上级清掉完成时间：开始过的回到进行中，没开始过的回到待办；
  /// 在归档里的，整件连同下级取回。说话不经这里：任务的状态只由明确的动作改。必须在写事务内调用。
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

  /// 汇总任务涉及的会话，资格统一由 `taskSessionCanEnd` 判断；事务事件入口也复用这里。任务离开看板（做完：你点圆圈 `completeTask`、Cue 做完 `finishTask`；归档 `archive`；删除 `trashCards`；
  /// 所在项目进回收站 `trashProject`），或明确开工换会话时（`insertDelivery`；纯关联不收尾），
  /// 写下改动之后对这件事里绑着的会话各看一遍，没人再用就请它所在的 Mac 结束：
  /// 1. 有还在看板上（`taskOpen`）、也没在开新会话的叶子绑着它（别的事的叶子也算），或有话正送进去（接着用它时话送到才绑上），留着；
  /// 2. 这件事的下一步（排在最前的还在看板上的子任务）还没开工、也没在往别处交，照交给的规则（`handOffPlan`）默认接着用它，留着；
  /// 3. 其余结束：没有下一步了、下一步换了别的会话、整件事完成、归档或删掉了。只结束有任务创建来源且 CuePad 托管的：
  ///    终端里你自己开的会话不替你结束（结束它就是关掉你的终端进程），它随这件事从看板收起（`isLoose`），再有动静才回来；做不到的（`canEnd`）也留着；
  ///    已结束的、记录还没到的不动。取回归档、撤销删除不重开：再对它说话就在后台恢复。
  /// `task` 是这件事里的任意一个任务，可以已经归档或删掉（删掉的从它原来的上级往上找这件事）；灵感不管。返回结束请求。必须在写事务内调用。
  @discardableResult
  func endUnusedSessions(of task: UUID, cue: Bool) throws -> UnusedSessions {
    guard let card = try find(Card.self, task), card.isTask else { return UnusedSessions() }
    let topID = try card.parentID.map { try ancestors(of: $0).last ?? $0 } ?? task
    guard let top = try find(Card.self, topID) else { return UnusedSessions() }
    let sessions = try db.query(
      """
      SELECT piSessionID FROM cards WHERE piSessionID IS NOT NULL AND (id = ?1 OR id IN (\(Self.subtree(from: "SELECT ?2"))))
      UNION SELECT sessionID FROM piSessionStates WHERE createdForTaskID IN (\(Self.subtree(from: "SELECT ?2", includingDeleted: true)))
      """, [task, topID]
    ) { $0.text(0) }
    guard !sessions.isEmpty else { return UnusedSessions() }
    let open = try select(
      Card.self, where: "id IN (SELECT value FROM json_each(?)) AND \(Self.taskOpen)", [Self.idList(try leaves(of: top).map(\.id))], orderBy: "sortKey, id")
    let launching = try launchingLeaves(open.map(\.id))
    var used = Set(open.filter { !launching.contains($0.id) }.compactMap(\.piSessionID))
    if let next = open.first, next.id != top.id, next.piSessionID == nil, !launching.contains(next.id), try sendingLeaves([next.id]).isEmpty,
      let continued = try continuableSession(for: next.id, agent: nil)
    {
      used.insert(continued.sessionID)
    }
    return try endUnused(sessions.filter { !used.contains($0) }, outside: top.id, cue: cue)
  }

  /// 这些会话里在 `root` 这件事之外也没人再用（`usedElsewhere`；nil 是哪件事都不除外）、CuePad 托管且做得到的（`PiSessionState.endsWithTask`），
  /// 请它所在的 Mac 结束；已结束的、记录还没到的不动。终端里你自己开的、还没结束的不结束，记进 `terminalKept`。必须在写事务内调用。
  func endUnused(_ sessions: [String], outside root: UUID?, cue: Bool) throws -> UnusedSessions {
    var result = UnusedSessions()
    for sessionID in sessions {
      guard try db.first(Self.usedElsewhere, [sessionID, root], { _ in true }) == nil, let state = try sessionState(sessionID) else { continue }
      if try taskSessionCanEnd(state), let owner = state.createdForTaskID {
        result.ended.append(try requestControl(.end, of: SendTarget(kind: .piSession, name: state.title, ref: sessionID), on: state.hostID, cue: cue,
          content: TaskSessionEnd(createdForTaskID: owner).stored))
      } else if !state.hosted, state.state != .known(.ended) {
        result.terminalKept = true
      }
    }
    return result
  }

  /// 会话（?1）在这件事（以 ?2 为根；NULL 是哪件事都不除外）之外还有用：别的事没做完的叶子绑着它，或有话正送进去。
  static let usedElsewhere = """
    SELECT 1 WHERE EXISTS (
        SELECT 1 FROM cards WHERE piSessionID = ?1 AND \(taskOpen)
          AND (?2 IS NULL OR id NOT IN (\(subtree(from: "SELECT ?2")))))
      OR EXISTS (
        SELECT 1 FROM deliveryRequests WHERE targetRef = ?1 AND mode IN (\(sqlList(DeliveryMode.toSession))) AND status IN (\(DeliveryStatus.openSQL)))
    """

  /// 任务此刻在做的叶子：叶子就是它自己，有子任务的是第一个没完成的子任务（没有就第一个）。不是任务抛 `notATask`。
  public func workingLeaf(of task: UUID) throws -> Card {
    try requireTask(task)
    guard let leaf = try find(Card.self, try homeLeaf(task)) else { throw CueStoreError.notFound }
    return leaf
  }

  /// 任务（或子任务）所在的顶层任务；不是任务抛 `notATask`。
  public func topTask(of task: UUID) throws -> UUID {
    try requireTask(task)
    return try ancestors(of: task).last ?? task
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

  /// 这件事的叶子：有子任务的是各子任务（按顺序），没有子任务的是它自己。
  func leaves(of task: Card) throws -> [Card] {
    let steps = try select(Card.self, where: "parentID = ? AND todoAt IS NOT NULL AND deletedAt IS NULL", [task.id], orderBy: "sortKey, id")
    return steps.isEmpty ? [task] : steps
  }
}
