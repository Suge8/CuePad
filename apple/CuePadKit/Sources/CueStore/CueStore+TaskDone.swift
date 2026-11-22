import CueText
import Foundation

extension CueStore {
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

  @discardableResult
  public func completeTask(_ id: UUID) throws -> TaskStatus {
    try write {
      guard let card = try find(Card.self, id) else { throw CueStoreError.notFound }
      guard let current = card.status else { throw CueStoreError.notATask }
      guard current != .done else { return .done }
      return try applyStatus(id, .done)
    }
  }

  public func completeTask(_ id: UUID, sleepingAt moment: Speech.Moment) throws -> (status: TaskStatus, unreached: [SessionState]) {
    try write { try completeSleeping(id, at: moment) }
  }

  private func completeSleeping(_ id: UUID, at moment: Speech.Moment) throws -> (status: TaskStatus, unreached: [SessionState]) {
    guard let card = try find(Card.self, id) else { throw CueStoreError.notFound }
    guard let current = card.status else { throw CueStoreError.notATask }
    let status = current == .done ? .done : try applyStatus(id, .done)
    guard status == .done else { return (status, []) }
    try reconcileTaskSessionEvents()
    var unreached: [SessionState] = []
    for session in try sessionsFreed(byCompleting: id) {
      if try macKnownOff(session.hostID, at: moment) != nil {
        unreached.append(session)
      } else {
        _ = try requestControl(
          .end, of: SendTarget(kind: .piSession, name: session.title, ref: session.sessionID), on: session.hostID, cue: false,
          content: DeliveryRequest.EndKind.explicit.stored)
      }
    }
    return (status, unreached)
  }

  public func sessionsEnding(byCompleting task: UUID, at moment: Speech.Moment) throws -> Set<String> {
    struct Rehearsed: Error { let sessions: Set<String> }
    do {
      _ = try db.transaction {
        let unreached = try completeSleeping(task, at: moment).unreached
        let ending = try db.query("SELECT DISTINCT r.targetRef FROM deliveryRequests AS r WHERE \(DeliveryRequest.endingSQL("r"))") { $0.text(0) }
        throw Rehearsed(sessions: Set(ending).union(unreached.map(\.sessionID)))
      }
    } catch let rehearsed as Rehearsed {
      return rehearsed.sessions
    }
    return []
  }

  public func uncompleteTask(_ id: UUID, completedAt time: Date) throws {
    try write {
      guard let card = try find(Card.self, id), card.completedAt == time, card.archivedAt == nil, card.deletedAt == nil else {
        throw CueStoreError.changedSinceUndo
      }
      let now = Date.stamp
      try db.run(
        "UPDATE cards SET completedAt = NULL, modifiedAt = ?1 WHERE id IN (\(Self.subtree(from: "SELECT ?2"))) AND completedAt = ?3 AND archivedAt IS NULL",
        [now, id, time])
      try db.run(
        "UPDATE cards SET startedAt = NULL, modifiedAt = ?1 WHERE id IN (SELECT value FROM json_each(?2)) AND startedAt = ?3 AND completedAt IS NULL",
        [now, Self.idList(try ancestors(of: id)), time])
    }
  }

  public func reopenTask(_ id: UUID) throws {
    try write { try reopen([id]) }
  }

  func reopenTasks(spokenToIn session: String, before: Date? = nil) throws {
    let done = try db.query(
      "SELECT id FROM cards WHERE piSessionID = ?1 AND completedAt IS NOT NULL AND (?2 IS NULL OR completedAt < ?2) AND \(Self.cardVisible)",
      [session, before]) { $0.uuid(0) }
    try reopen(done)
    let now = Date.stamp
    for task in done { try beginTask(task, at: now) }
  }

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
