import Foundation

extension CueStore {
  static let keptRetention: TimeInterval = 7 * 86_400

  @discardableResult
  public func deleteExpiredDeliveries(at now: Date? = nil, host: String? = nil, pulledAt: Date? = nil) throws -> Date? {
    try write { try removeExpiredDeliveries(among: nil, at: now ?? timing.now(), host: host, pulledAt: pulledAt) }
  }

  @discardableResult
  func removeExpiredDeliveries(among ids: Set<UUID>?, at now: Date, host: String? = nil, pulledAt: Date? = nil) throws -> Date? {
    if ids?.isEmpty == true { return nil }
    let requests = if let ids {
      try select(DeliveryRequest.self, where: "id IN (SELECT value FROM json_each(?))", [Self.idList(ids)])
    } else {
      try select(DeliveryRequest.self)
    }
    var removable: [UUID] = [], next: Date?
    for request in requests {
      guard let at = try removableAt(request) else { continue }
      var until = now
      if request.hostID != host, request.status.known.map(DeliveryStatus.open.contains) != false {
        guard let pulledAt else { continue }
        until = min(now, pulledAt)
      }
      if at <= until { removable.append(request.id) } else { next = min(next ?? at, at) }
    }
    if !removable.isEmpty { try db.run("DELETE FROM deliveryRequests WHERE id IN (SELECT value FROM json_each(?))", [Self.idList(removable)]) }
    return next
  }

  private func removableAt(_ request: DeliveryRequest) throws -> Date? {
    guard let status = request.status.known else { return nil }
    let kept = Self.keptRetention, short = DeliveryExecutor.retention.seconds
    switch status {
    case .pending, .preparing: return request.dispatchDeadline?.addingTimeInterval(kept)
    case .executing, .confirming: return request.deadlineAt?.addingTimeInterval(kept)
    case .succeeded, .failed, .unconfirmed: break
    }
    guard let completed = request.completedAt else { return nil }
    let mode = request.mode.known, origin = request.origin
    switch status {
    case .unconfirmed: return completed.addingTimeInterval(kept)
    case .failed:
      let keep = mode == .send || mode == .withdraw || mode == .start || origin == .known(.cue)
      return completed.addingTimeInterval(keep ? kept : short)
    default: break
    }
    switch mode {
    case .send:
      if try messageUploaded(request.id), try sessionBindingDisposition(request) == .settled { return completed }
      return completed.addingTimeInterval(kept)
    case .withdraw: return completed.addingTimeInterval(kept)
    case .start:
      if try !awaitsClaim(request), try sessionBindingDisposition(request) == .settled { return completed.addingTimeInterval(short) }
      return completed.addingTimeInterval(DeliveryRequest.phaseLimit)
    default: return completed.addingTimeInterval(short)
    }
  }

  private func messageUploaded(_ id: UUID) throws -> Bool {
    try db.first("""
      SELECT 1 FROM piMessages m JOIN syncRecords s ON s.recordName = m.id WHERE m.deliveryID = ? AND s.pushedModifiedAt IS NOT NULL
      """, [id]) { _ in true } ?? false
  }

  private func awaitsClaim(_ request: DeliveryRequest) throws -> Bool {
    guard request.cardID != nil else { return false }
    return try db.first("""
      SELECT 1 FROM deliveryRequests WHERE id = ? AND \(Self.latestHandoff("deliveryRequests")) AND \(Self.launchUnclaimed)
      """, [request.id]) { _ in true } ?? false
  }

  func releaseDeliveryBindings(of cards: [UUID]) throws {
    guard !cards.isEmpty else { return }
    try db.run("""
      UPDATE deliveryRequests SET cardID = NULL, sessionBindingRevision = NULL, modifiedAt = ?
      WHERE cardID IN (SELECT value FROM json_each(?))
      """, [Date.stamp, Self.idList(cards)])
  }
}
