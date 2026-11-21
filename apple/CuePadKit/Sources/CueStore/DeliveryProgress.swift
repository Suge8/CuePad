import Foundation

extension DeliveryRequest {
  func progress(after outcome: DeliveryOutcome, at completed: Date, resuming: Bool = false) -> (DeliveryStatus, ShownText?, Date?) {
    let (status, reason): (DeliveryStatus, ShownText?) =
      switch outcome {
      case .succeeded: (.succeeded, nil)
      case .confirming where !resuming && deadlineAt.map({ completed < $0 }) != true:
        (.unconfirmed, Speech.unconfirmedReason)
      case .confirming: (.confirming, nil)
      case .failed(let reason): (.failed, reason)
      case .unconfirmed(let reason): (.unconfirmed, reason)
      }
    let deadline = status == .confirming && !resuming ? completed.addingTimeInterval(Speech.receiptLimit) : deadlineAt
    return (status, reason, deadline)
  }

  static func mergingProgress(local: SyncRow, remote: SyncRow) -> SyncRow? {
    func progress(_ row: SyncRow) -> Int {
      switch row.text("status").flatMap(DeliveryStatus.init(rawValue:)) {
      case .succeeded: 6
      case .unconfirmed: 5
      case .failed: 4
      case .confirming: 3
      case .executing: 2
      case .preparing: 1
      case .pending: 0
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
  func confirmDeliveries(among ids: Set<UUID>, session: String) throws {
    guard !ids.isEmpty else { return }
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
    if awaitingResult {
      try db.run(
        "UPDATE deliveryRequests SET resultReceivedAt = ? WHERE id = ? AND status IN ('\(DeliveryStatus.succeeded.rawValue)', '\(DeliveryStatus.failed.rawValue)')",
        [Date.stamp, remote.id])
    }
  }

  private func isAwaitingResult(_ id: String) throws -> Bool {
    try db.first(
      "SELECT 1 FROM deliveryRequests WHERE id = ? AND (status IN (\(DeliveryStatus.openSQL)) OR status = '\(DeliveryStatus.unconfirmed.rawValue)')", [id]) { _ in true } != nil
  }
}
