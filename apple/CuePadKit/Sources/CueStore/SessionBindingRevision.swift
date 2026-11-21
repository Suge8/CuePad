import Foundation

public struct SessionBindingRevision: Equatable, Sendable, StoredJSON, Comparable {
  let generation: Int
  let explicit: Bool
  let id: UUID
  var fulfilled: Bool

  init(after previous: Self?, explicit: Bool) {
    generation = (previous?.generation ?? 0) + 1
    self.explicit = explicit
    id = UUID()
    fulfilled = explicit
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.generation != rhs.generation { return lhs.generation < rhs.generation }
    if lhs.explicit != rhs.explicit { return !lhs.explicit }
    if lhs.id == rhs.id { return !lhs.fulfilled && rhs.fulfilled }
    return lhs.id.uuidString < rhs.id.uuidString
  }
}

extension CueStore {
  func reviseSessionBinding(_ card: UUID, explicit: Bool) throws -> SessionBindingRevision {
    let previous = try find(Card.self, card)?.sessionBindingRevision
    let revision = SessionBindingRevision(after: previous, explicit: explicit)
    try db.run("UPDATE cards SET sessionBindingRevision = ?, modifiedAt = ? WHERE id = ?", [revision.stored, Date.stamp, card])
    return revision
  }

  enum SessionBindingDisposition {
    case awaitingCard, applicable, settled
  }

  func sessionBindingDisposition(_ request: DeliveryRequest) throws -> SessionBindingDisposition {
    guard let id = request.cardID, let revision = request.sessionBindingRevision else { return .settled }
    guard let card = try find(Card.self, id) else { return .awaitingCard }
    guard card.deletedAt == nil else { return .settled }
    if card.isTask, try homeLeaf(id) != id { return .settled }
    guard let current = card.sessionBindingRevision else { return .awaitingCard }
    if current.id == revision.id { return current.fulfilled ? .settled : .applicable }
    return current > revision ? .settled : .awaitingCard
  }

  func acceptsSessionBinding(_ request: DeliveryRequest) throws -> Bool {
    try sessionBindingDisposition(request) == .applicable
  }

  static func mergingSessionBinding(local: SyncRow, remote: SyncRow, into winner: SyncRow) -> SyncRow {
    let localRevision = local.text("sessionBindingRevision").flatMap(SessionBindingRevision.init(stored:))
    let remoteRevision = remote.text("sessionBindingRevision").flatMap(SessionBindingRevision.init(stored:))
    let binding: SyncRow
    switch (localRevision, remoteRevision) {
    case (let lhs?, let rhs?) where lhs != rhs: binding = lhs > rhs ? local : remote
    case (_?, nil): binding = local
    case (nil, _?): binding = remote
    default: binding = winner
    }
    var merged = winner
    for field in ["piSessionID", "formerSessionIDs", "sessionBindingRevision"] { merged.fields[field] = binding.fields[field] ?? .null }
    return merged
  }
}
