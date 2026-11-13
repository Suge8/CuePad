import CueText
import Foundation

extension CueStore {
  /// 发送记录只记“内容”的投送。发给 Pi 会话时，灵感与任务都在同一事务里记下交给了哪个会话（`linkCard`）。执行投送的那台 Mac 记，请求从哪台设备发来都一样。灵感发出去不变成任务。
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

  /// 纯记账，不重放卡片绑定。历史回填与主动投送共用同一份发送记录。
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

  /// 已受理内容的发送记录；主动关联另走 linkDeliveredCard，历史回填不带这个副作用。
  public func recordDelivery(_ request: DeliveryRequest, content: String, to target: SendTarget) throws {
    try write {
      if try db.first("SELECT 1 FROM sendRecords WHERE deliveryID = ?", [request.id], { _ in true }) != nil { return }
      try insertSendRecord(content, to: target, card: request.cardID, delivery: request.id, origin: request.origin)
    }
  }

  /// 执行中的主动关联，不同于历史记账。请求写下后用户已经改绑或解绑的，不能被晚到的 ACK 抢回去。
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

  /// 卡片、请求或成功回执晚到时兑现原关联意图；只用仍在库里的请求及其修订，不从发送历史猜测。
  /// start 的目标由 launchToken 认领；已有会话的内容与命令按成功请求的固定目标补齐。
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

  /// 统一来源分类里有 Cue 正证据的投送；请求先到、发送记录先到或请求已清理都按同一条规则。
  public func cueSentDeliveries(among deliveries: some Sequence<UUID>) throws -> Set<UUID> {
    Set(try deliverySources(among: deliveries).compactMap { $0.value == .cue ? $0.key : nil })
  }

  /// 不写发送记录：发给 Agent 的命令带着卡片时用。没开始的任务进行中；完成了的不变。任务的会话只记在叶子上（`homeLeaf`）；一个叶子最多一个会话，一个会话可以绑好几个叶子。
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

  /// 叶子换上会话 `new`（SQL 表达式）的 UPDATE 里与 `piSessionID` 一起写的：换下的会话记进 `formerSessionIDs` 末尾，
  /// 换上的（以前用过又换回来的）从里面拿掉，正在用的不在里面。只记任务的：灵感交给别的会话不算用过。
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

  /// 有子任务的抛 `notALeaf`，不是任务抛 `notATask`。叶子原来绑着的会话换成这个；同一个会话可以绑好几个叶子。没开始的任务置为进行中，完成了的不变。绑会话不发任务的正文：它在做的事已经在会话里。
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
        (piSessionID = ?1 OR EXISTS (SELECT 1 FROM json_each(cards.formerSessionIDs) WHERE value = ?1))
          AND todoAt IS NOT NULL AND deletedAt IS NULL AND archivedAt IS NULL AND \(Self.isLeaf("cards"))
        """,
      [sessionID], orderBy: "startedAt, id"
    ).map { LeafTask(task: $0, parent: try $0.parentID.flatMap { try find(Card.self, $0) }) }
  }

  /// 会话所在的各处：它属于的叶子任务（`tasks(boundTo:)`）与它们的上级。挂在会话上的提问（`questionsOn`）、一轮兜底时这个会话有没有去处都按它认。
  func sessionPlaces(_ sessionID: String) throws -> [UUID] {
    try tasks(boundTo: sessionID).flatMap { [$0.task.id, $0.parent?.id] }.compactMap(\.self)
  }

  /// （项目页的任务顺序：同级手动顺序，子任务紧跟上级）。`project` 是会话所在的项目；会话没归项目（文件夹没绑给哪个项目）时列默认项目的。
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

  static func isLeaf(_ alias: String) -> String {
    "NOT EXISTS (SELECT 1 FROM cards s WHERE s.parentID = \(alias).id AND s.todoAt IS NOT NULL AND s.deletedAt IS NULL)"
  }
}
