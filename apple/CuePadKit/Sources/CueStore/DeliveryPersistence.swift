import Foundation

extension CueStore {
  /// 发给本机、还没有派发期限锚点的（这台写给自己、还没传上去的）按写下的时刻锚定（`DeliveryRequest.serverAt`）：
  /// 监听与派发读取共用这个事务（不依赖执行队列），等待与到期从此只读这一个锚点。拉到的请求入库时就带着服务器收下的时刻，这里碰不到。
  func actionableDeliveries(for host: String) throws -> [DeliveryRequest] {
    try write {
      try db.run("""
        UPDATE deliveryRequests SET serverAt = createdAt
        WHERE hostID = ? AND serverAt IS NULL AND status IN (\(DeliveryStatus.waitingSQL)) AND handledBy IS NULL
        """, [host])
      return try pendingDeliveries(for: host)
    }
  }

  func pendingDeliveries(for host: String) throws -> [DeliveryRequest] {
    try select(
      DeliveryRequest.self, where: "status IN (\(DeliveryStatus.waitingSQL)) AND handledBy IS NULL AND hostID = ?", [host],
      orderBy: "CASE WHEN mode = 'withdraw' THEN 0 ELSE 1 END, createdAt, rowid")
  }

  /// 起进程等可能有副作用的操作在这里领取；不能退回准备。执行起来就不再是准备时的说明（`failure`）：
  /// 留着的话，执行中断后核对不出结果时会把"准备就绪"这类旧说明当成未确认的原因。
  func claimDelivery(_ id: UUID, host: String, until deadline: Date) throws -> DeliveryRequest? {
    try write {
      try db.run(
        """
        UPDATE deliveryRequests AS r SET status = 'executing', handledBy = ?, deadlineAt = ?, failure = NULL,
          modifiedAt = MAX(modifiedAt + 1, ?) WHERE id = ? AND status IN (\(DeliveryStatus.waitingSQL)) AND handledBy IS NULL
          AND \(DeliveryRequest.dispatchDeadlineSQL("r")) > ?
          AND NOT (\(Self.abandonedDelivery))
        """, [host, deadline, Date.stamp, id, timing.now()])
      guard db.changes > 0, var claimed = try find(DeliveryRequest.self, id) else { return nil }
      guard try permitsTaskSessionEnd(claimed) else {
        _ = try applyDeliveryOutcome(claimed, .failed(ShownText(CueStoreError.sessionInUse(claimed.target.name))), at: timing.now())
        return nil
      }
      if !claimed.isFromCue, let mode = claimed.mode.known, DeliveryMode.toSession.contains(mode),
        claimed.target.kind == .known(.piSession), let session = claimed.target.ref {
        try reopenTasks(spokenToIn: session, before: claimed.createdAt)
      }
      if claimed.mode == .known(.end) {
        claimed.coveredEndRequests = [claimed.id]
        if claimed.content == "end", let session = claimed.target.ref {
          claimed.coveredEndRequests.formUnion(try db.query("""
            SELECT id FROM deliveryRequests WHERE mode = 'end' AND targetRef = ? AND hostID = ? AND handledBy = ?
              AND status IN ('executing', 'confirming', 'unconfirmed', 'pending')
            """, [session, host, host]) { $0.uuid(0) })
        }
      }
      return claimed
    }
  }

  func reserveDeliveryTarget(_ id: UUID, host: String) throws -> DeliveryRequest? {
    try write {
      try db.run("""
        UPDATE deliveryRequests AS r SET status = 'preparing', handledBy = ?, failure = ?,
          modifiedAt = MAX(modifiedAt + 1, ?) WHERE id = ? AND status IN (\(DeliveryStatus.waitingSQL)) AND handledBy IS NULL
          AND \(DeliveryRequest.dispatchDeadlineSQL("r")) > ?
          AND NOT (\(Self.abandonedDelivery))
        """, [host, DeliveryPreparation.ready.stored, Date.stamp, id, timing.now()])
      return db.changes > 0 ? try find(DeliveryRequest.self, id) : nil
    }
  }

  /// preparing 的准备权不授权副作用；旧 pending 领取事实不在这里恢复。
  func releaseDeliveryReservations(for host: String, only id: UUID? = nil) throws {
    try write {
      try db.run("""
        UPDATE deliveryRequests SET handledBy = NULL, modifiedAt = MAX(modifiedAt + 1, ?1)
        WHERE hostID = ?2 AND status = 'preparing' AND (?3 IS NULL OR id = ?3)
        """, [Date.stamp, host, id])
    }
  }

  func beginDelivery(_ id: UUID, on host: String, until deadline: Date) throws -> DeliveryRequest? {
    try write {
      try db.run("""
        UPDATE deliveryRequests AS r SET status = 'executing', deadlineAt = ?, failure = NULL,
          modifiedAt = MAX(modifiedAt + 1, ?) WHERE id = ? AND status = 'preparing' AND handledBy = ?
          AND \(DeliveryRequest.dispatchDeadlineSQL("r")) > ?
          AND NOT (\(Self.abandonedDelivery))
        """, [deadline, Date.stamp, id, host, timing.now()])
      return db.changes > 0 ? try find(DeliveryRequest.self, id) : nil
    }
  }

  public func completeDeliveryWithdrawal(_ request: DeliveryRequest, on host: String, refused: ShownText) throws -> DeliveryOutcome {
    try write {
      guard request.mode == .known(.withdraw), let current = try find(DeliveryRequest.self, request.id),
        current.status == .known(.executing), current.handledBy == host, let original = UUID(uuidString: current.content)
      else { return .unconfirmed(Speech.unconfirmedReason) }
      let outcome: DeliveryOutcome = try (removeUnstartedDelivery(original, locallyOn: host) || removeFailedDelivery(original)) ? .succeeded : .failed(refused)
      _ = try applyDeliveryOutcome(current, outcome, at: timing.now())
      return outcome
    }
  }

  /// 写回结果：失败的原因随 `DeliveryOutcome.failed` 一起来，没有不带原因的失败。
  /// 只改还没有结果的（放弃的是待领取的、执行的是执行中的），不覆盖已经写下的结果。
  /// 任务的状态与正文都不因说话而变：发出的正文留在任务上，"发过没有"看投送请求。
  /// 你的作答成功了，同一个事务里往那个会话的对话写下你答了什么（`ChatRole.answer`；Cue 替你答的不写，记在它那一轮的经过里）。
  func finishDelivery(_ request: DeliveryRequest, _ outcome: DeliveryOutcome, at completed: Date) throws -> Bool {
    try write { try applyDeliveryOutcome(request, outcome, at: completed) }
  }

  private func applyDeliveryOutcome(_ request: DeliveryRequest, _ outcome: DeliveryOutcome, at completed: Date) throws -> Bool {
    let id = request.id
    let (status, reason, deadline) = request.progress(after: outcome, at: completed)
    try db.run(
      """
      UPDATE deliveryRequests SET status = ?, failure = ?, completedAt = ?, deadlineAt = ?, modifiedAt = MAX(modifiedAt + 1, ?)
      WHERE id = ? AND status = ? AND status != ?
      """, [status.rawValue, reason?.stored, status == .confirming ? nil as Date? : completed, deadline, Date.stamp, id, request.status.rawValue, status.rawValue])
    let changed = db.changes > 0
    if !changed {
      let current = try find(DeliveryRequest.self, id)
      return current?.status == .known(status) && current?.reason == reason
    }
    if status == .succeeded { try reconcileDeliveredCards(deliveries: [id]) }
    guard changed, status == .succeeded, let request = try find(DeliveryRequest.self, id), !request.isFromCue,
      let answer = request.answer, let session = request.target.ref
    else { return changed }
    // 排在会话文件里此刻最后一条之后（作答时 Agent 停着等你，接下来的都在它之后）；对话按 `at` 把它插到答的那一刻：
    // 你写下作答请求的时刻，不是这里执行完的时刻（离线答的、Mac 晚领取的，执行晚于答）
    let seq = try db.first("SELECT MAX(seq) FROM piMessages WHERE sessionID = ?", [session]) { $0.isNull(0) ? 0 : $0.int(0) } ?? 0
    _ = try insert(
      ChatMessage(
        sessionID: session, entryID: "answer/\(id.uuidString.lowercased())", seq: seq, role: .answer, text: answer.value.said, at: request.createdAt,
        deliveryID: id, question: answer.question, shownText: answer.value.shown),
      ignoringExisting: true)
    return changed
  }

  // 本机写入次序不受手机与 Mac 的钟差影响；同步 UPDATE 不改变 rowid。
  private static let abandonedDelivery = """
    r.mode IN (\(sqlList(DeliveryMode.requiresReadySession.sorted { $0.rawValue < $1.rawValue }))) AND (
      EXISTS (SELECT 1 FROM deliveryRequests AS e WHERE e.hostID = r.hostID AND e.targetKind = r.targetKind
        AND e.targetRef = r.targetRef AND e.mode = 'end' AND e.rowid > r.rowid)
      OR EXISTS (SELECT 1 FROM deliveryRequests AS c WHERE c.mode = 'withdraw' AND c.content = r.id))
    """

  func isDeliveryAbandoned(_ id: UUID) throws -> Bool {
    try db.first("SELECT 1 FROM deliveryRequests AS r WHERE r.id = ? AND (\(Self.abandonedDelivery))", [id]) { _ in true } ?? false
  }

  /// 只有执行 Mac 可证明整个操作未开始；发送设备的旧准备快照不能自行写失败。
  func abandonPreparedDeliveries(for host: String) throws -> [UUID] {
    try write {
      let predicate = "r.hostID = ?1 AND (r.status = 'preparing' OR (r.status = 'pending' AND r.handledBy IS NULL)) AND (\(Self.abandonedDelivery))"
      let ids = try db.query("SELECT r.id FROM deliveryRequests AS r WHERE \(predicate)", [host]) { $0.uuid(0) }
      if !ids.isEmpty {
        try db.run("""
          UPDATE deliveryRequests AS r SET status = 'not_delivered', failure = ?2, completedAt = ?3,
            modifiedAt = MAX(modifiedAt + 1, ?3) WHERE \(predicate)
          """, [host, DeliveryPreparation.abandoned.stored, Date.stamp])
      }
      return ids
    }
  }

  public func mayBeginDelivery(_ id: UUID) throws -> Bool {
    try db.first("""
      SELECT 1 FROM deliveryRequests AS r WHERE r.id = ? AND r.status = 'executing' AND r.deadlineAt > ?
        AND NOT (\(Self.abandonedDelivery))
      """, [id, timing.now()]) { _ in true } ?? false
  }

  /// 等现有会话就绪时转准备，写下在等什么；派发期限不变。归还准备权与到期写失败在同一事务里；executing 与任何未知结果不可能从这里退回。
  func awaitDeliveryTarget(_ request: DeliveryRequest, reason: ShownText) throws -> DeliveryRequest? {
    try write {
      try db.run(
        """
        UPDATE deliveryRequests AS r SET status = 'preparing', handledBy = NULL, failure = ?, modifiedAt = MAX(modifiedAt + 1, ?)
        WHERE id = ? AND status = ? AND status IN (\(DeliveryStatus.waitingSQL))
        """, [reason.stored, Date.stamp, request.id, request.status.rawValue])
      guard db.changes > 0, let current = try find(DeliveryRequest.self, request.id) else { return nil }
      if let due = current.dispatchDeadline, timing.now() >= due {
        _ = try applyDeliveryOutcome(current, .failed(current.expiry), at: timing.now())
      }
      return try find(DeliveryRequest.self, request.id)
    }
  }

  func deliveryTargetReady(_ id: UUID) throws {
    try write {
      try db.run("""
        UPDATE deliveryRequests SET failure = ?, modifiedAt = MAX(modifiedAt + 1, ?) WHERE id = ? AND status = 'preparing' AND handledBy IS NULL
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
    try select(
      DeliveryRequest.self,
      where: "hostID = ? AND (status IN ('executing', 'confirming', 'unconfirmed') OR (status = 'pending' AND handledBy IS NOT NULL))", [host])
  }

  /// 删除完成时间早于 `cutoff` 的请求；返回还剩什么：`transient` 是按保留期清的还有（下一轮一个保留期后），`oldestKept` 是留到 7 天的里最早完成的那条（下一轮等它到期）。
  /// 认领靠请求留着：带着灵感或任务、已成功的开新会话请求在被认领前留着（`claimLaunchedCards`），有可靠修订的原关联未决同样等到 `claimCutoff`。发出的话不按普通保留期清：消息上云且原关联已解决才提前收走（`markPushed`），否则等到 `keptCutoff`；没能送达、没能开成的留着等用户重发或移除；结果未确认的留着等正证据对账；Cue 发起的失败请求留着给 Cue 看（`cueChanges`）。
  /// 成功请求的关联等待有界：send 七天、command 六十秒、start 六百秒，均从完成时间算，不续期；超窗只删除请求，不改关联修订。
  func deleteCompletedDeliveries(before cutoff: Date, claimCutoff: Date, keptCutoff: Date) throws -> (transient: Bool, oldestKept: Date?) {
    let done = "status IN ('\(DeliveryStatus.succeeded.rawValue)', '\(DeliveryStatus.failed.rawValue)', '\(DeliveryStatus.unconfirmed.rawValue)')"
    let kept = """
      completedAt >= ?3 AND (mode IN ('send', 'withdraw') OR (mode = 'start' AND status = '\(DeliveryStatus.failed.rawValue)') OR status = '\(DeliveryStatus.unconfirmed.rawValue)' OR (status = '\(DeliveryStatus.failed.rawValue)' AND origin IS '\(DeliveryOrigin.cue.rawValue)'))
      """
    let awaitingClaim = """
      mode = 'start' AND status = '\(DeliveryStatus.succeeded.rawValue)' AND cardID IS NOT NULL AND completedAt >= ?2
        AND \(Self.latestHandoff("deliveryRequests")) AND \(Self.launchUnclaimed)
      """
    let arguments: [any SQLBindable] = [cutoff, claimCutoff, keptCutoff]
    return try write {
      let expired = try select(DeliveryRequest.self,
        where: """
          \(done) AND ((completedAt < ?1 AND NOT (\(awaitingClaim)) AND NOT (\(kept)))
            OR (mode = 'send' AND status = 'succeeded' AND \(Self.deliveryMessageUploaded)))
          """, arguments)
      for (mode, requests) in Dictionary(grouping: expired, by: \.mode) {
        let bindingCutoff = switch mode {
        case .known(.send): keptCutoff
        case .known(.start): claimCutoff
        default: cutoff
        }
        try removeDeliveries(requests, completedBefore: bindingCutoff)
      }
      let transient = try db.first("SELECT 1 FROM deliveryRequests WHERE \(done) AND NOT (\(kept))", arguments) { _ in true } != nil
      let oldestKept = try db.first("SELECT MIN(completedAt) FROM deliveryRequests WHERE \(done) AND (\(kept))", arguments) { $0.dateOrNil(0) } ?? nil
      return (transient, oldestKept)
    }
  }
}
