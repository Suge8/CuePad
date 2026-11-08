import Foundation

/// 只给关联字段排序：回执沿用发起意图的修订，不因晚到获得更高权限。
/// 并发同代明确关联优先于投送；同类按操作身份确定收敛，不比较设备时钟。同一意图只从待兑现前进到已兑现，正文编辑不撤销它。
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

  /// 请求只授权创建时选定的卡片，不能随层级变化重选叶子。缺卡或旧版卡片不证明意图已结束；
  /// 兑现、新修订、删除与原卡不再是叶子才解除保留。无可靠修订的历史不重建意图。
  func sessionBindingDisposition(_ request: DeliveryRequest) throws -> SessionBindingDisposition {
    guard let id = request.cardID, let revision = request.sessionBindingRevision else { return .settled }
    guard let card = try find(Card.self, id) else {
      let deleted = try db.first("SELECT 1 FROM syncRecords WHERE recordName = ? AND recordType = 'cards'", [id]) { _ in true } ?? false
      return deleted ? .settled : .awaitingCard
    }
    guard card.deletedAt == nil else { return .settled }
    if card.isTask, try homeLeaf(id) != id { return .settled }
    guard let current = card.sessionBindingRevision else { return .awaitingCard }
    if current.id == revision.id { return current.fulfilled ? .settled : .applicable }
    return current > revision ? .settled : .awaitingCard
  }

  func acceptsSessionBinding(_ request: DeliveryRequest) throws -> Bool {
    try sessionBindingDisposition(request) == .applicable
  }

  /// 整行的版本仍负责正文等字段；关联意图独立比较，旧 ACK 的晚写入不能覆盖明确解绑。
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
