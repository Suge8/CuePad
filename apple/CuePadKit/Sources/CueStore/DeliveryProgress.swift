import Foundation

extension DeliveryRequest {
  func progress(after outcome: DeliveryOutcome, at completed: Date) -> (DeliveryStatus, ShownText?, Date?) {
    let (status, reason): (DeliveryStatus, ShownText?) =
      switch outcome {
      case .succeeded: (.succeeded, nil)
      case .confirming where deadlineAt.map({ completed < $0 }) != true:
        (.unconfirmed, Speech.unconfirmedReason)
      case .confirming: (.confirming, nil)
      case .failed(let reason): (.failed, reason)
      case .unconfirmed(let reason): (.unconfirmed, reason)
      }
    let deadline = status == .confirming ? completed.addingTimeInterval(Speech.receiptLimit) : deadlineAt
    return (status, reason, deadline)
  }

  /// 旧 pending 或迟到的错误不能把已交出的意图退回可执行。正证据成功优先于未知，未知优先于失败。
  static func mergingProgress(local: SyncRow, remote: SyncRow) -> SyncRow? {
    func progress(_ row: SyncRow) -> Int {
      switch row.text("status").flatMap(DeliveryStatus.init(rawValue:)) {
      case .succeeded: 6
      case .unconfirmed: 5
      case .failed: 4
      case .confirming: 3
      case .executing: 2
      case .preparing: 1
      case .pending: row.text("handledBy") == nil ? 0 : 2
      case nil: 5
      }
    }
    let localProgress = progress(local), remoteProgress = progress(remote)
    let samePhase = local.text("status") == remote.text("status")
    func deadline(_ row: SyncRow) -> Int64? {
      if case .int(let value) = row.fields["deadlineAt"] { value } else { nil }
    }
    let due = [deadline(local), deadline(remote)].compactMap { $0 }.min()
    let preservesDeadline = samePhase && due != deadline(remote)
    let preservesProgress = localProgress != remoteProgress && (localProgress > remoteProgress || local.modifiedAt > remote.modifiedAt)
    guard preservesDeadline || preservesProgress else { return nil }
    var repaired = local.modifiedAt > remote.modifiedAt ? local : remote
    let resolved = localProgress > remoteProgress ? local : remote
    for column in ["status", "failure", "handledBy", "completedAt", "deadlineAt"] { repaired.fields[column] = resolved.fields[column] }
    if samePhase { repaired.fields["deadlineAt"] = due.map(SQLValue.int) ?? .null }
    repaired.fields["modifiedAt"] = .int(max(local.modifiedAt, remote.modifiedAt) + 1)
    return repaired
  }
}

extension CueStore {
  /// 本机读历史或同步读到真实消息后，投送只向已送达收敛。先落消息，再在同一事务认账，不受请求／消息到达顺序影响。
  func confirmDeliveries(among ids: Set<UUID>, session: String) throws {
    guard !ids.isEmpty else { return }
    // 消息上服务器之后才收走请求（markPushed）；这之前原气泡由该消息接替。
    try db.run("""
      UPDATE deliveryRequests SET status = 'succeeded', failure = NULL,
        completedAt = ?1, modifiedAt = MAX(modifiedAt + 1, ?1)
      WHERE status != 'succeeded' AND mode IN (\(DeliveryMode.landsAsMessageSQL)) AND id IN (SELECT value FROM json_each(?2))
        AND (targetRef = ?3 OR mode = 'start')
      """, [Date.stamp, Self.idList(ids), session])
    try reconcileDeliveredCards(deliveries: ids)
  }

  func applyIncomingDelivery(_ remote: SyncRow, systemFields: Data, serverAt: Date?) throws {
    let awaitingResult = try isAwaitingResult(remote.id)
    try applyVersion(remote, systemFields)
    if let serverAt { try db.run("UPDATE deliveryRequests SET serverAt = ? WHERE id = ? AND serverAt IS NULL", [serverAt, remote.id]) }
    // 旧同步快照仍带着领取事实，却把状态退回 pending：入库时就收口为未知，不只在执行器里跳过。
    try db.run(
      """
      UPDATE deliveryRequests SET status = '\(DeliveryStatus.unconfirmed.rawValue)', failure = ?2, completedAt = COALESCE(completedAt, ?3), modifiedAt = MAX(modifiedAt + 1, ?3)
      WHERE id = ?1 AND status = '\(DeliveryStatus.pending.rawValue)' AND handledBy IS NOT NULL
      """, [remote.id, DeliveryRequest.interruptedReason.stored, Date.stamp])
    if awaitingResult {
      try db.run(
        "UPDATE deliveryRequests SET resultReceivedAt = ? WHERE id = ? AND status IN ('\(DeliveryStatus.succeeded.rawValue)', '\(DeliveryStatus.failed.rawValue)')",
        [Date.stamp, remote.id])
    }
  }

  /// 投送请求在本机还在等结果：远端版本把它变成完成时，记下本机时刻（往返时间的终点）。
  /// 执行方在本机写结果，不走远端应用；第一次就收到已完成请求的设备从没等过它，也不记。
  private func isAwaitingResult(_ id: String) throws -> Bool {
    try db.first(
      "SELECT 1 FROM deliveryRequests WHERE id = ? AND (status IN (\(DeliveryStatus.openSQL)) OR status = '\(DeliveryStatus.unconfirmed.rawValue)')", [id]) { _ in true } != nil
  }
}
