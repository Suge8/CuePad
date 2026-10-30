import Foundation

extension CueStore {
  func pendingDeliveries(for host: String) throws -> [DeliveryRequest] {
    try select(
      DeliveryRequest.self, where: "status IN ('pending', 'preparing') AND handledBy IS NULL AND hostID = ?", [host],
      orderBy: "CASE WHEN mode = 'withdraw' THEN 0 ELSE 1 END, createdAt, rowid")
  }

  /// 附件准备也有自己的期限；同一 pending 阶段只写一次。
  func prepareDelivery(_ id: UUID, until deadline: Date) throws -> DeliveryRequest? {
    try write {
      try db.run(
        "UPDATE deliveryRequests SET deadlineAt = ?, modifiedAt = MAX(modifiedAt + 1, ?) WHERE id = ? AND status = 'pending' AND handledBy IS NULL AND deadlineAt IS NULL",
        [deadline, Date.stamp, id])
      let current = try find(DeliveryRequest.self, id)
      return current?.isWithdrawable == true ? current : nil
    }
  }

  /// 起进程等可能有副作用的操作在这里领取；不能退回准备。
  func claimDelivery(_ id: UUID, host: String, until deadline: Date) throws -> DeliveryRequest? {
    try write {
      try db.run(
        """
        UPDATE deliveryRequests AS r SET status = 'executing', handledBy = ?, deadlineAt = ?,
          modifiedAt = MAX(modifiedAt + 1, ?) WHERE id = ? AND status IN ('pending', 'preparing') AND handledBy IS NULL
          AND (deadlineAt IS NULL OR deadlineAt > ?)
          AND NOT (\(Self.abandonedDelivery))
        """, [host, deadline, Date.stamp, id, timing.now()])
      return db.changes > 0 ? try find(DeliveryRequest.self, id) : nil
    }
  }

  func reserveDeliveryTarget(_ id: UUID, host: String, until deadline: Date) throws -> DeliveryRequest? {
    try write {
      try db.run("""
        UPDATE deliveryRequests AS r SET status = 'preparing', handledBy = ?, failure = ?, deadlineAt = COALESCE(deadlineAt, ?),
          modifiedAt = MAX(modifiedAt + 1, ?) WHERE id = ? AND status IN ('pending', 'preparing') AND handledBy IS NULL
          AND (deadlineAt IS NULL OR deadlineAt > ?)
          AND NOT (\(Self.abandonedDelivery))
        """, [host, DeliveryPreparation.ready.stored, deadline, Date.stamp, id, timing.now()])
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
        UPDATE deliveryRequests AS r SET status = 'executing', deadlineAt = ?,
          modifiedAt = MAX(modifiedAt + 1, ?) WHERE id = ? AND status = 'preparing' AND handledBy = ?
          AND (deadlineAt IS NULL OR deadlineAt > ?)
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
  /// 你的作答成功了，同一个事务里往那个会话的对话写下你答了什么（`PiChatRole.answer`；Cue 替你答的不写，记在它那一轮的经过里）。
  func finishDelivery(_ request: DeliveryRequest, _ outcome: DeliveryOutcome, at completed: Date) throws -> Bool {
    try write { try applyDeliveryOutcome(request, outcome, at: completed) }
  }

  private func applyDeliveryOutcome(_ request: DeliveryRequest, _ outcome: DeliveryOutcome, at completed: Date) throws -> Bool {
    let id = request.id
    let (status, reason): (DeliveryStatus, ShownText?) =
      switch outcome {
      case .succeeded: (.succeeded, nil)
      case .confirming where request.deadlineAt.map({ completed < $0 }) != true:
        (.unconfirmed, Speech.unconfirmedReason)
      case .confirming: (.confirming, nil)
      case .failed(let reason): (.failed, reason)
      case .unconfirmed(let reason): (.unconfirmed, reason)
      }
    let deadline = status == .confirming ? completed.addingTimeInterval(Speech.receiptLimit) : request.deadlineAt
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
    guard changed, status == .succeeded, let request = try find(DeliveryRequest.self, id), !request.isFromCue,
      let answer = request.answer, let session = request.target.ref
    else { return changed }
    // 排在会话文件里此刻最后一条之后（作答时 Agent 停着等你，接下来的都在它之后）；对话按 `at` 把它插到答的那一刻：
    // 你写下作答请求的时刻，不是这里执行完的时刻（离线答的、Mac 晚领取的，执行晚于答）
    let seq = try db.first("SELECT MAX(seq) FROM piMessages WHERE sessionID = ?", [session]) { $0.isNull(0) ? 0 : $0.int(0) } ?? 0
    _ = try insert(
      PiChatMessage(
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
      SELECT 1 FROM deliveryRequests AS r WHERE r.id = ? AND r.status = 'executing' AND (r.deadlineAt IS NULL OR r.deadlineAt > ?)
        AND NOT (\(Self.abandonedDelivery))
      """, [id, timing.now()]) { _ in true } ?? false
  }

  /// 只能归还尚未开始的准备权；executing 与任何未知结果不可能从这里退回。
  func awaitDeliveryTarget(_ request: DeliveryRequest, reason: ShownText, until deadline: Date) throws -> DeliveryRequest? {
    try write {
      try db.run(
        """
        UPDATE deliveryRequests SET status = 'preparing', handledBy = NULL, failure = ?, deadlineAt = COALESCE(deadlineAt, ?),
          modifiedAt = MAX(modifiedAt + 1, ?)
        WHERE id = ? AND status = ? AND status IN ('pending', 'preparing')
        """, [reason.stored, deadline, Date.stamp, request.id, request.status.rawValue])
      let current = try find(DeliveryRequest.self, request.id)
      return current?.status == .known(.preparing) && current?.handledBy == nil ? current : nil
    }
  }

  func deliveryTargetReady(_ id: UUID) throws {
    try write {
      try db.run("""
        UPDATE deliveryRequests SET failure = ?, modifiedAt = MAX(modifiedAt + 1, ?) WHERE id = ? AND status = 'preparing' AND handledBy IS NULL
        """, [DeliveryPreparation.ready.stored, Date.stamp, id])
    }
  }

  /// 重开只恢复核对，绝不把领取事实退回 pending；旧记录没有期限，也不补造一段新等待。
  func unsettledDeliveries(for host: String) throws -> [DeliveryRequest] {
    try select(
      DeliveryRequest.self,
      where: "hostID = ? AND (status IN ('executing', 'confirming', 'unconfirmed') OR (status = 'pending' AND handledBy IS NOT NULL))", [host])
  }

  /// 删除完成时间早于 `cutoff` 的请求；返回是否还剩已完成的（还剩就再排一轮）。
  /// 带着灵感或任务、已成功的开新会话请求在被认领前留着（会话记录可能晚到，认领靠它，见 `claimLaunchedCards`），
  /// 最多等到完成时间早于 `claimCutoff`（会话记录始终没到）；认领了、失败了、或之后又交给了别处（不会再被认领）就按保留期清理。
  /// 发出的话（`send`）不按保留期清：送到的等它在对话里的那条消息上了服务器再收走（`markPushed`），气泡才不会在消息到别的设备之前没了；
  /// 没能送达的留着等用户重发或移除（重发写成后移除它）。Cue 发起的请求失败了留着给 Cue 醒来时看（`cueChanges`）。
  /// 这几种都至多留到完成早于 `keptCutoff`。
  func deleteCompletedDeliveries(before cutoff: Date, claimCutoff: Date, keptCutoff: Date) throws -> Bool {
    let done = "status IN ('\(DeliveryStatus.succeeded.rawValue)', '\(DeliveryStatus.failed.rawValue)')"
    let kept = """
      completedAt >= ?3 AND (mode IN ('send', 'withdraw') OR (status = '\(DeliveryStatus.failed.rawValue)' AND origin IS '\(DeliveryOrigin.cue.rawValue)'))
      """
    let awaitingClaim = """
      mode = 'start' AND status = '\(DeliveryStatus.succeeded.rawValue)' AND cardID IS NOT NULL AND completedAt >= ?2
        AND \(Self.latestHandoff("deliveryRequests")) AND \(Self.launchUnclaimed)
      """
    let arguments: [any SQLBindable] = [cutoff, claimCutoff, keptCutoff]
    return try write {
      try db.run(
        "DELETE FROM deliveryRequests WHERE \(done) AND completedAt < ?1 AND NOT (\(awaitingClaim)) AND NOT (\(kept))",
        arguments)
      return try db.first("SELECT 1 FROM deliveryRequests WHERE \(done) AND NOT (\(kept))", arguments) { _ in true } != nil
    }
  }
}
