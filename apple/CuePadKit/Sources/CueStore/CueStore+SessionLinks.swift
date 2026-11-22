import CueText
import Foundation

extension CueStore {
  @discardableResult
  public func recordSend(
    _ content: String, to target: SendTarget, card: UUID? = nil, delivery: UUID? = nil, origin: Open<DeliveryOrigin>? = nil
  ) throws -> SendRecord {
    try write {
      if let delivery, let existing = try select(SendRecord.self, where: "deliveryID = ?", [delivery]).first { return existing }
      let record = try insertSendRecord(content, to: target, card: card, delivery: delivery, origin: origin)
      if let card, target.kind == .known(.piSession), let session = target.ref {
        if let delivery {
          if let request = try find(DeliveryRequest.self, delivery) { try linkDeliveredCardInTransaction(request, toSession: session) }
        } else {
          try linkCardInTransaction(card, toSession: session, at: Date.stamp)
        }
      }
      return record
    }
  }

  @discardableResult
  func insertSendRecord(
    _ content: String, to target: SendTarget, card: UUID?, delivery: UUID?, origin: Open<DeliveryOrigin>?
  ) throws -> SendRecord {
    let now = Date.stamp
    let record = SendRecord(
      id: UUID(), content: content, targetKind: target.kind, targetName: target.name,
      targetRef: target.ref, cardID: card, sentAt: now, modifiedAt: now, deliveryID: delivery, origin: origin)
    try insert(record)
    try registerAttachments(in: content)
    return record
  }

  public func recordDelivery(_ request: DeliveryRequest, content: String, to target: SendTarget) throws {
    try write {
      if try db.first("SELECT 1 FROM sendRecords WHERE deliveryID = ?", [request.id], { _ in true }) != nil { return }
      try insertSendRecord(content, to: target, card: request.cardID, delivery: request.id, origin: request.origin)
    }
  }

  public func linkDeliveredCard(_ request: DeliveryRequest, toSession session: String) throws {
    try write { try linkDeliveredCardInTransaction(request, toSession: session) }
  }

  func linkDeliveredCardInTransaction(_ request: DeliveryRequest, toSession session: String) throws {
    guard let card = request.cardID, try acceptsSessionBinding(request),
      try find(DeliveryRequest.self, request.id)?.cardID == card else { return }
    try linkExactCardInTransaction(card, toSession: session, at: Date.stamp)
    if var revision = request.sessionBindingRevision, try find(Card.self, card)?.sessionBindingRevision?.fulfilled != true {
      revision.fulfilled = true
      try db.run("UPDATE cards SET sessionBindingRevision = ?, modifiedAt = ? WHERE id = ?", [revision.stored, Date.stamp, card])
    }
  }

  func reconcileDeliveredCards(cards: Set<UUID> = [], deliveries: Set<UUID> = []) throws {
    guard !cards.isEmpty || !deliveries.isEmpty else { return }
    let requests = try select(DeliveryRequest.self, where: """
      status = 'succeeded' AND mode IN ('send', 'command') AND targetKind = 'piSession' AND targetRef IS NOT NULL
        AND (cardID IN (SELECT value FROM json_each(?1)) OR id IN (SELECT value FROM json_each(?2)))
      """, [Self.idList(cards), Self.idList(deliveries)])
    for request in requests {
      if let session = request.target.ref { try linkDeliveredCardInTransaction(request, toSession: session) }
    }
  }

  public func linkCard(_ card: UUID, toSession session: String) throws {
    try write { try linkCardInTransaction(card, toSession: session, at: Date.stamp) }
  }

  private func linkCardInTransaction(_ card: UUID, toSession session: String, at now: Date) throws {
    guard let link = try link(of: card) else { return }
    let leaf = link.isTask ? try homeLeaf(card) : card
    try linkExactCardInTransaction(leaf, toSession: session, at: now)
  }

  private func linkExactCardInTransaction(_ id: UUID, toSession session: String, at now: Date) throws {
    guard let card = try find(Card.self, id), card.piSessionID != session else { return }
    try db.run(
      """
      UPDATE cards SET \(Self.keepingFormerSession("?1")), piSessionID = ?1, modifiedAt = ?2
      WHERE id = ?3
      """, [session, now, id])
    if card.isTask { try beginTask(id, at: now) }
  }

  static func keepingFormerSession(_ new: String) -> String {
    """
    formerSessionIDs = CASE WHEN cards.todoAt IS NULL THEN cards.formerSessionIDs ELSE (
      SELECT CASE WHEN COUNT(*) = 0 THEN NULL ELSE json_group_array(sid) END FROM (
        SELECT f.value AS sid FROM json_each(COALESCE(cards.formerSessionIDs, '[]')) f WHERE f.value <> \(new)
        UNION ALL
        SELECT cards.piSessionID WHERE cards.piSessionID <> \(new)
          AND NOT EXISTS (SELECT 1 FROM json_each(COALESCE(cards.formerSessionIDs, '[]')) f WHERE f.value = cards.piSessionID)))
    END
    """
  }

  public func bindSession(_ sessionID: String, to task: UUID) throws {
    try write {
      guard let link = try link(of: task) else { throw CueStoreError.notFound }
      guard link.isTask else { throw CueStoreError.notATask }
      guard try homeLeaf(task) == task else { throw CueStoreError.notALeaf }
      guard let session = try sessionState(sessionID) else { throw CueStoreError.notFound }
      guard link.project == (session.projectID ?? Project.defaultID) else { throw CueStoreError.invalidProject }
      let current = try find(Card.self, task)
      guard current?.piSessionID != sessionID || current?.sessionBindingRevision?.explicit != true else { return }
      try requireSessionAvailable(sessionID)
      _ = try reviseSessionBinding(task, explicit: true)
      try linkCardInTransaction(task, toSession: sessionID, at: Date.stamp)
    }
  }

  public func unbindSession(from task: UUID) throws {
    try write {
      let card = try requireLeaf(task)
      guard card.piSessionID != nil || card.sessionBindingRevision?.explicit != true else { return }
      _ = try reviseSessionBinding(task, explicit: true)
      try db.run("UPDATE cards SET piSessionID = NULL, modifiedAt = ? WHERE id = ?", [Date.stamp, task])
    }
  }

  public func tasks(boundTo sessionID: String) throws -> [LeafTask] {
    try select(
      Card.self,
      where: """
        \(Self.usedSession("cards", "?1")) AND \(Self.taskOnBoard()) AND \(Self.isLeaf("cards"))
        """,
      [sessionID], orderBy: "startedAt, id"
    ).map { LeafTask(task: $0, parent: try $0.parentID.flatMap { try find(Card.self, $0) }) }
  }

  func sessionPlaces(_ sessionID: String) throws -> [UUID] {
    try tasks(boundTo: sessionID).flatMap { [$0.task.id, $0.parent?.id] }.compactMap(\.self)
  }

  public func bindableTasks(in project: UUID?) throws -> [LeafTask] {
    let open = try tasks(in: project ?? Project.defaultID, .todo, .inProgress)
    let byID = Dictionary(open.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let leaves = try Set(db.query("SELECT id FROM cards c WHERE c.todoAt IS NOT NULL AND \(Self.isLeaf("c"))") { $0.uuid(0) })
    var result: [LeafTask] = []
    for task in open where task.piSessionID == nil && leaves.contains(task.id) {
      var parent = task.parentID.flatMap { byID[$0] }
      if parent == nil, let id = task.parentID { parent = try find(Card.self, id) }
      result.append(LeafTask(task: task, parent: parent))
    }
    return result
  }

  static func usedSession(_ alias: String, _ session: String) -> String {
    """
    (\(alias).piSessionID = \(session) OR (\(alias).formerSessionIDs IS NOT NULL
      AND EXISTS (SELECT 1 FROM json_each(\(alias).formerSessionIDs) WHERE value = \(session))))
    """
  }

  static func sessionsUsed(where condition: String) -> String {
    """
    SELECT piSessionID FROM cards WHERE piSessionID IS NOT NULL AND (\(condition))
    UNION SELECT f.value FROM (SELECT formerSessionIDs FROM cards WHERE formerSessionIDs IS NOT NULL AND (\(condition))) c, json_each(c.formerSessionIDs) f
    """
  }

  static func isLeaf(_ alias: String) -> String {
    "NOT EXISTS (SELECT 1 FROM cards s WHERE s.parentID = \(alias).id AND s.todoAt IS NOT NULL AND s.deletedAt IS NULL)"
  }
}
