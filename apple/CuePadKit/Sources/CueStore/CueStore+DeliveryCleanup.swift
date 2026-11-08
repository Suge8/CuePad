import Foundation

extension CueStore {
  /// 消息上云后，窗口内仍保留未决关联的原请求；七天上限沿用完成时间，不因重启或同步续期。
  /// 到期只清请求，不把缺卡解释成删除，也不伪造关联兑现。
  func removeUploadedDeliveries(among ids: Set<UUID>) throws {
    guard !ids.isEmpty else { return }
    let requests = try select(DeliveryRequest.self, where: """
      mode = 'send' AND status = 'succeeded' AND id IN (SELECT value FROM json_each(?))
        AND \(Self.deliveryMessageUploaded)
      """, [Self.idList(ids)])
    try removeDeliveries(requests, completedBefore: timing.now().addingTimeInterval(-DeliveryExecutor.keptRetention))
  }

  /// 永久删除原卡同时解除请求的关联引用；删除事实无需另存，后续回执只记送达。
  func releaseDeliveryBindings(of cards: [UUID]) throws {
    guard !cards.isEmpty else { return }
    try db.run("""
      UPDATE deliveryRequests SET cardID = NULL, sessionBindingRevision = NULL, modifiedAt = ?
      WHERE cardID IN (SELECT value FROM json_each(?))
      """, [Date.stamp, Self.idList(cards)])
  }

  static let deliveryMessageUploaded = """
    EXISTS (SELECT 1 FROM piMessages m JOIN syncRecords s ON s.recordName = m.id
      WHERE m.deliveryID = deliveryRequests.id AND s.pushedModifiedAt IS NOT NULL)
    """

  /// 展示条件由调用方筛选；关联资格只在窗口内阻止清理，达到原保留上限无条件释放。
  func removeDeliveries(_ requests: [DeliveryRequest], completedBefore cutoff: Date) throws {
    let removable = try requests.filter { request in
      guard request.status == .known(.succeeded), [.known(.send), .known(.command), .known(.start)].contains(request.mode) else { return true }
      if let completed = request.completedAt, completed < cutoff { return true }
      return try sessionBindingDisposition(request) == .settled
    }
    guard !removable.isEmpty else { return }
    try db.run("DELETE FROM deliveryRequests WHERE id IN (SELECT value FROM json_each(?))", [Self.idList(removable.map(\.id))])
  }
}
