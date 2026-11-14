import Foundation

extension CueStore {
  /// 发给本机、还没有派发期限锚点的（这台写给自己、还没传上去的）按写下的时刻锚定（`DeliveryRequest.serverAt`）：
  /// 监听与派发读取共用这个事务（不依赖执行队列），等待与到期从此只读这一个锚点。拉到的请求入库时就带着服务器收下的时刻，这里碰不到。
  func actionableDeliveries(for host: String) throws -> [DeliveryRequest] {
    try write {
      try db.run("""
        UPDATE deliveryRequests SET serverAt = createdAt
        WHERE hostID = ? AND serverAt IS NULL AND status IN (\(DeliveryStatus.waitingSQL))
        """, [host])
      return try pendingDeliveries(for: host)
    }
  }

  func pendingDeliveries(for host: String) throws -> [DeliveryRequest] {
    try select(
      DeliveryRequest.self, where: "status IN (\(DeliveryStatus.waitingSQL)) AND hostID = ?", [host],
      orderBy: "CASE WHEN mode = 'withdraw' THEN 0 ELSE 1 END, createdAt, rowid")
  }

  /// 起进程等可能有副作用的操作在这里领取；不能退回准备。执行起来就不再是准备时的说明（`failure`）：
  /// 留着的话，执行中断后核对不出结果时会把"准备就绪"这类旧说明当成未确认的原因。
  func claimDelivery(_ id: UUID, host: String, until deadline: Date) throws -> DeliveryRequest? {
    try write {
      try db.run(
        """
        UPDATE deliveryRequests AS r SET status = 'executing', handledBy = ?, deadlineAt = ?, failure = NULL,
          modifiedAt = MAX(modifiedAt + 1, ?) WHERE id = ? AND status IN (\(DeliveryStatus.waitingSQL))
          AND \(DeliveryRequest.dispatchDeadlineSQL("r")) > ?
          AND NOT (\(Self.abandonedDelivery))
        """, [host, deadline, Date.stamp, id, timing.now()])
      guard db.changes > 0, var claimed = try find(DeliveryRequest.self, id) else { return nil }
      guard try permitsTaskSessionEnd(claimed) else {
        try applyDeliveryOutcome(claimed, .failed(ShownText(CueStoreError.sessionInUse(claimed.target.name))), at: timing.now())
        return nil
      }
      if !claimed.isFromCue, let mode = claimed.mode.known, DeliveryMode.toSession.contains(mode),
        claimed.target.kind == .known(.piSession), let session = claimed.target.ref {
        try reopenTasks(spokenToIn: session, before: claimed.createdAt)
      }
      if claimed.mode == .known(.end) {
        claimed.coveredEndRequests = [claimed.id]
        // 点名的结束也了结这台已领取、结果还没定的旧结束
        if claimed.end == .explicit, let session = claimed.target.ref {
          claimed.coveredEndRequests.formUnion(try db.query("""
            SELECT id FROM deliveryRequests AS r WHERE \(DeliveryRequest.endingSQL("r")) AND r.targetRef = ? AND r.hostID = ? AND r.handledBy = ?
              AND r.status IN (\(DeliveryStatus.claimedSQL))
            """, [session, host, host]) { $0.uuid(0) })
        }
      }
      return claimed
    }
  }

  /// 撤回在库里一个事务办完，不交给 handler、没有执行中这一步：原请求还没领取就删掉它（不经过失败），已领取的撤不回。
  /// 撤回请求一写进库，原请求就领不走了（`abandonedDelivery`），所以排在它前面的领取与它不会交错。
  /// `request` 是执行器读到时的版本；进事务前它可能已被到期写成失败，那就不再动原请求。
  func settleWithdrawal(_ request: DeliveryRequest, on host: String) throws {
    try write {
      guard try find(DeliveryRequest.self, request.id)?.status == request.status else { return }
      let removed = try UUID(uuidString: request.content).map { try removeUnstartedDelivery($0, locallyOn: host) || removeFailedDelivery($0) } ?? false
      try applyDeliveryOutcome(request, removed ? .succeeded : .failed(DeliveryRequest.withdrawRefused), at: timing.now())
    }
  }

  /// 写回结果：失败的原因随 `DeliveryOutcome.failed` 一起来，没有不带原因的失败。
  /// 只改还没有结果的（放弃的是待领取的、执行的是执行中的），不覆盖已经写下的结果。
  /// 任务的状态与正文都不因说话而变：发出的正文留在任务上，"发过没有"看投送请求。
  /// 你的作答成功了，同一个事务里往那个会话的对话写下你答了什么（`ChatRole.answer`；Cue 替你答的不写，记在它那一轮的经过里）。
  func finishDelivery(_ request: DeliveryRequest, _ outcome: DeliveryOutcome, at completed: Date, resuming: Bool = false) throws {
    try write { try applyDeliveryOutcome(request, outcome, at: completed, resuming: resuming) }
  }

  private func applyDeliveryOutcome(_ request: DeliveryRequest, _ outcome: DeliveryOutcome, at completed: Date, resuming: Bool = false) throws {
    let id = request.id
    let (status, reason, deadline) = request.progress(after: outcome, at: completed, resuming: resuming)
    try db.run(
      """
      UPDATE deliveryRequests SET status = ?, failure = ?, completedAt = ?, deadlineAt = ?, modifiedAt = MAX(modifiedAt + 1, ?)
      WHERE id = ? AND status = ? AND status != ?
      """, [status.rawValue, reason?.stored, status == .confirming ? nil as Date? : completed, deadline, Date.stamp, id, request.status.rawValue, status.rawValue])
    guard db.changes > 0, status == .succeeded else { return }
    try reconcileDeliveredCards(deliveries: [id])
    guard let request = try find(DeliveryRequest.self, id), !request.isFromCue, let answer = request.answer, let session = request.target.ref
    else { return }
    // 排在会话文件里此刻最后一条之后（作答时 Agent 停着等你，接下来的都在它之后）；对话按 `at` 把它插到答的那一刻：
    // 你写下作答请求的时刻，不是这里执行完的时刻（离线答的、Mac 晚领取的，执行晚于答）
    let seq = try db.first("SELECT MAX(seq) FROM piMessages WHERE sessionID = ?", [session]) { $0.isNull(0) ? 0 : $0.int(0) } ?? 0
    _ = try insert(
      ChatMessage(
        sessionID: session, entryID: "answer/\(id.uuidString.lowercased())", seq: seq, role: .answer, text: answer.value.said, at: request.createdAt,
        deliveryID: id, question: answer.question, shownText: answer.value.shown),
      ignoringExisting: true)
  }

  /// 之后对同一会话写了结束（没失败的：成了或还在办）：话不再派发，没领取的写成放弃（`abandonPreparedDeliveries`），领取了还没交出的不交（`mayBeginDelivery`）。
  /// 本机写入次序不受手机与 Mac 的钟差影响；同步 UPDATE 不改变 rowid。
  private static let endedLater = """
    r.mode IN (\(sqlList(DeliveryMode.requiresReadySession.sorted { $0.rawValue < $1.rawValue }))) AND
      EXISTS (SELECT 1 FROM deliveryRequests AS e WHERE e.hostID = r.hostID AND e.targetKind = r.targetKind
        AND e.targetRef = r.targetRef AND e.mode = 'end' AND e.status <> '\(DeliveryStatus.failed.rawValue)' AND e.rowid > r.rowid)
    """

  /// 领不走的：之后写了结束，或有撤回在等着办（撤回自己删它，不先写失败）。
  private static let abandonedDelivery = """
    (\(endedLater)) OR EXISTS (SELECT 1 FROM deliveryRequests AS c WHERE c.mode = 'withdraw' AND c.content = r.id)
    """

  func isDeliveryAbandoned(_ id: UUID) throws -> Bool {
    try db.first("SELECT 1 FROM deliveryRequests AS r WHERE r.id = ? AND (\(Self.abandonedDelivery))", [id]) { _ in true } ?? false
  }

  /// 只有执行 Mac 可证明整个操作未开始；发送设备的旧准备快照不能自行写失败。
  func abandonPreparedDeliveries(for host: String) throws {
    try write {
      let predicate = "r.hostID = ?1 AND r.status IN (\(DeliveryStatus.waitingSQL)) AND (\(Self.endedLater))"
      try db.run("""
        UPDATE deliveryRequests AS r SET status = 'not_delivered', failure = ?2, completedAt = ?3,
          modifiedAt = MAX(modifiedAt + 1, ?3) WHERE \(predicate)
        """, [host, DeliveryPreparation.abandoned.stored, Date.stamp])
    }
  }

  public func mayBeginDelivery(_ id: UUID) throws -> Bool {
    try db.first("""
      SELECT 1 FROM deliveryRequests AS r WHERE r.id = ? AND r.status = 'executing' AND r.deadlineAt > ?
        AND NOT (\(Self.endedLater))
      """, [id, timing.now()]) { _ in true } ?? false
  }

  /// 等现有会话就绪时转准备，写下在等什么；派发期限不变，到期写失败在同一事务里；executing 与任何未知结果不可能从这里退回。
  func awaitDeliveryTarget(_ request: DeliveryRequest, reason: ShownText) throws -> DeliveryRequest? {
    try write {
      try db.run(
        """
        UPDATE deliveryRequests AS r SET status = 'preparing', failure = ?, modifiedAt = MAX(modifiedAt + 1, ?)
        WHERE id = ? AND status = ? AND status IN (\(DeliveryStatus.waitingSQL))
        """, [reason.stored, Date.stamp, request.id, request.status.rawValue])
      guard db.changes > 0, let current = try find(DeliveryRequest.self, request.id) else { return nil }
      if let due = current.dispatchDeadline, timing.now() >= due {
        try applyDeliveryOutcome(current, .failed(current.expiry), at: timing.now())
      }
      return try find(DeliveryRequest.self, request.id)
    }
  }

  func deliveryTargetReady(_ id: UUID) throws {
    try write {
      try db.run("""
        UPDATE deliveryRequests SET failure = ?, modifiedAt = MAX(modifiedAt + 1, ?) WHERE id = ? AND status = 'preparing'
        """, [DeliveryPreparation.ready.stored, Date.stamp, id])
    }
  }

  /// 派发期限已到、还没领取的（没有锚点的还不算）；还没到的登记到期重读：期限监视订阅它，到点就叫醒（`DeliveryExecutor`）。
  func expiredUnclaimedDeliveries(for host: String) throws -> [DeliveryRequest] {
    let now = timing.now()
    return try pendingDeliveries(for: host).filter { request in
      guard let due = request.dispatchDeadline else { return false }
      guard due > now else { return true }
      expire(at: due)
      return false
    }
  }

  /// 重开只恢复核对，绝不把领取事实退回 pending；旧记录没有期限，也不补造一段新等待。
  func unsettledDeliveries(for host: String) throws -> [DeliveryRequest] {
    try select(DeliveryRequest.self, where: "hostID = ? AND status IN (\(DeliveryStatus.claimedSQL))", [host])
  }

}
