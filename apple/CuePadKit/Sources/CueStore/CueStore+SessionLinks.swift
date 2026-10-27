import CueText
import Foundation

extension CueStore {
  /// 记录一次投送或复制：内容快照、目标、时间。发送记录只记"内容"的投送——说给 Agent 的话、发到应用、复制；命令与设置（config、answer、end、stop、bind、command）不记。发给 Pi 会话时，灵感与任务都在同一事务里记下交给了哪个会话（`linkCard`；任务行据此显示会话状态）。执行投送的那台 Mac 记，
  /// 请求从哪台设备发来都一样。灵感发出去不变成任务。经投送请求送出的带上请求的 id 与来源（`delivery`、`origin`）。
  @discardableResult
  public func recordSend(
    _ content: String, to target: SendTarget, card: UUID? = nil, delivery: UUID? = nil, origin: Open<DeliveryOrigin>? = nil
  ) throws -> SendRecord {
    try write {
      let now = Date.stamp
      let record = SendRecord(
        id: UUID(), content: content, targetKind: target.kind, targetName: target.name,
        targetRef: target.ref, cardID: card, sentAt: now, modifiedAt: now, deliveryID: delivery, origin: origin)
      try insert(record)
      try registerAttachments(in: content)
      if let card, target.kind == .known(.piSession), let session = target.ref { try linkCardInTransaction(card, toSession: session, at: now) }
      return record
    }
  }

  /// `deliveries`（会话消息的 `PiChatMessage.deliveryID`）里哪些是 Cue 说的：按发送记录认，送出它的请求清理了也认得出。
  public func cueSentDeliveries(among deliveries: some Sequence<UUID>) throws -> Set<UUID> {
    Set(try db.query(
      "SELECT deliveryID FROM sendRecords WHERE origin = '\(DeliveryOrigin.cue.rawValue)' AND deliveryID IN (SELECT value FROM json_each(?))",
      [Self.idList(deliveries)]) { $0.uuid(0) })
  }

  /// 把灵感或任务关联到一个会话（没开始的任务进行中；完成了的不变：说话不改任务的状态），不写发送记录：
  /// 发给 Agent 的命令带着卡片时用（命令不是内容的投送，发送记录只记内容）。任务的会话只记在叶子上（`homeLeaf`）；
  /// 一个叶子最多一个会话，一个会话可以绑好几个叶子。
  public func linkCard(_ card: UUID, toSession session: String) throws {
    try write { try linkCardInTransaction(card, toSession: session, at: Date.stamp) }
  }

  private func linkCardInTransaction(_ card: UUID, toSession session: String, at now: Date) throws {
    guard let link = try link(of: card) else { return }
    try db.run(
      """
      UPDATE cards SET \(Self.keepingFormerSession("?1")), piSessionID = ?1, modifiedAt = ?2,
        startedAt = CASE WHEN todoAt IS NOT NULL THEN COALESCE(startedAt, ?2) END
      WHERE id = ?3
      """, [session, now, link.isTask ? try homeLeaf(card) : card])
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

  /// 把会话绑到叶子任务 `task` 上（会话页的"绑定到任务"、任务的右键）：叶子是没有子任务的任务，有子任务的抛 `notALeaf`，不是任务抛 `notATask`。
  /// 叶子原来绑着的会话换成这个；同一个会话可以绑好几个叶子（已完成的事绑着的会话照样能绑给新的事）。没开始的任务置为进行中，完成了的不变。
  /// 绑会话不发任务的正文：它在做的事已经在会话里，要说的话在会话里说。
  public func bindSession(_ sessionID: String, to task: UUID) throws {
    try write {
      guard let link = try link(of: task) else { throw CueStoreError.notFound }
      guard link.isTask else { throw CueStoreError.notATask }
      guard try homeLeaf(task) == task else { throw CueStoreError.notALeaf }
      try forgetLaunches(of: task)
      try linkCardInTransaction(task, toSession: sessionID, at: Date.stamp)
      try endUnusedSessions(of: task, cue: false)
    }
  }

  /// 解开叶子任务 `task` 绑着的会话：任务状态不变，会话照常（没有别的任务绑着它就是没绑任务的会话）。
  public func unbindSession(from task: UUID) throws {
    try write {
      try forgetLaunches(of: task)
      try db.run("UPDATE cards SET piSessionID = NULL, modifiedAt = ? WHERE id = ? AND piSessionID IS NOT NULL", [Date.stamp, task])
    }
  }

  /// 用户亲手绑定、解绑是之后的一次交给：指向这个任务的开新会话请求不再认领它（`claimLaunchedCards` 只认最近一次），
  /// 否则那个会话的记录一写（或同步过来）就把它抢回去；它们也就不再算"正在开会话"（`launchingLeaves` 按请求带着的卡认）。
  private func forgetLaunches(of task: UUID) throws {
    try db.run("UPDATE deliveryRequests SET cardID = NULL, modifiedAt = ? WHERE cardID = ? AND mode = 'start'", [Date.stamp, task])
  }

  /// 这个会话属于的叶子任务：正在用它的与以前用过它的（`formerSessionIDs`；没删除、没归档，含完成了的），先开始的在前；子任务带着上级。
  /// 正在用它的是 `piSessionID` 等于它的那几个。
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

  /// 能绑会话的叶子（没完成、没绑会话、没删除、没归档）：子任务带着上级一起给，界面写"上级 · 子任务"。顺序同 `tasks(in:_:)`
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

  /// 表 `alias` 里的任务是叶子：没有（没删除的）子任务。
  static func isLeaf(_ alias: String) -> String {
    "NOT EXISTS (SELECT 1 FROM cards s WHERE s.parentID = \(alias).id AND s.todoAt IS NOT NULL AND s.deletedAt IS NULL)"
  }
}
