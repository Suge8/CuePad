import Foundation

extension CueStore {
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

  func settleWithdrawal(_ request: DeliveryRequest, on host: String) throws {
    try write {
      guard try find(DeliveryRequest.self, request.id)?.status == request.status else { return }
      let removed = try UUID(uuidString: request.content).map { try removeUnstartedDelivery($0, locallyOn: host) || removeFailedDelivery($0) } ?? false
      try applyDeliveryOutcome(request, removed ? .succeeded : .failed(DeliveryRequest.withdrawRefused), at: timing.now())
    }
  }

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
    let seq = try db.first("SELECT MAX(seq) FROM piMessages WHERE sessionID = ?", [session]) { $0.isNull(0) ? 0 : $0.int(0) } ?? 0
    _ = try insert(
      ChatMessage(
        sessionID: session, entryID: "answer/\(id.uuidString.lowercased())", seq: seq, role: .answer, text: answer.value.said, at: request.createdAt,
        deliveryID: id, question: answer.question, shownText: answer.value.shown),
      ignoringExisting: true)
  }

  private static let endedLater = """
    r.mode IN (\(sqlList(DeliveryMode.requiresReadySession.sorted { $0.rawValue < $1.rawValue }))) AND
      EXISTS (SELECT 1 FROM deliveryRequests AS e WHERE e.hostID = r.hostID AND e.targetKind = r.targetKind
        AND e.targetRef = r.targetRef AND e.mode = 'end' AND e.status <> '\(DeliveryStatus.failed.rawValue)' AND e.rowid > r.rowid)
    """

  private static let abandonedDelivery = """
    (\(endedLater)) OR EXISTS (SELECT 1 FROM deliveryRequests AS c WHERE c.mode = 'withdraw' AND c.content = r.id)
    """

  func isDeliveryAbandoned(_ id: UUID) throws -> Bool {
    try db.first("SELECT 1 FROM deliveryRequests AS r WHERE r.id = ? AND (\(Self.abandonedDelivery))", [id]) { _ in true } ?? false
  }

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

  func expiredUnclaimedDeliveries(for host: String) throws -> [DeliveryRequest] {
    let now = timing.now()
    return try pendingDeliveries(for: host).filter { request in
      guard let due = request.dispatchDeadline else { return false }
      guard due > now else { return true }
      expire(at: due)
      return false
    }
  }

  func unsettledDeliveries(for host: String) throws -> [DeliveryRequest] {
    try select(DeliveryRequest.self, where: "hostID = ? AND status IN (\(DeliveryStatus.claimedSQL))", [host])
  }

}
