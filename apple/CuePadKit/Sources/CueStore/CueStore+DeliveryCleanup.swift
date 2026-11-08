import Foundation

extension CueStore {
  /// 消息上云只解除气泡保留；带可靠修订的成功请求还要等原关联意图兑现、被取代或删除。
  /// 卡片晚到后由定时清理重新核对上传事实，不另存待清理状态。
  func removeUploadedDeliveries(among ids: Set<UUID>) throws {
    guard !ids.isEmpty else { return }
    let requests = try select(DeliveryRequest.self, where: """
      mode = 'send' AND status = 'succeeded' AND id IN (SELECT value FROM json_each(?))
        AND \(Self.deliveryMessageUploaded)
      """, [Self.idList(ids)])
    try removeSettledDeliveries(requests)
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

  /// 上传回执与保留期清理共用资格；其他结果仍沿用各自保留期，无修订的旧记录不猜测关联。
  func removeSettledDeliveries(_ requests: [DeliveryRequest]) throws {
    let removable = try requests.filter { request in
      guard request.status == .known(.succeeded), [.known(.send), .known(.command), .known(.start)].contains(request.mode) else { return true }
      return try sessionBindingDisposition(request) == .settled
    }
    guard !removable.isEmpty else { return }
    try db.run("DELETE FROM deliveryRequests WHERE id IN (SELECT value FROM json_each(?))", [Self.idList(removable.map(\.id))])
  }
}
