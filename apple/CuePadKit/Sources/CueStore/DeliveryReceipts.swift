import Foundation

extension CueStore {
  /// 消息历史、结束状态及后续成功控制请求的正证据共用写回；事实先入库，再单向收敛，旧回执不倒退结果。
  func confirmDeliveryResults(_ evidence: String, _ bindings: [any SQLBindable]) throws {
    try db.run("""
      UPDATE deliveryRequests AS r SET status = 'succeeded', failure = NULL,
        completedAt = ?1, modifiedAt = MAX(modifiedAt + 1, ?1)
      WHERE status != 'succeeded' AND (\(evidence))
      """, [Date.stamp] + bindings)
  }

  /// 重启后的结束请求仍只按正证据恢复，不再次派发。
  public func confirmEndedDelivery(_ id: UUID) throws -> Bool {
    try write {
      guard let request = try find(DeliveryRequest.self, id), request.mode == .known(.end), let session = request.target.ref else { return false }
      try confirmSessionEnd(session)
      return try find(DeliveryRequest.self, id)?.status == .known(.succeeded)
    }
  }

  /// ended 是结束正证据；必须来自执行 host、且不早于该 host 的领取时刻（执行期限减 phaseLimit）。
  /// 不比较发送设备的创建时间，避免手机钟差；后续成功的明确 end 也能确认此前未知的 end。
  /// 不凭离线、歇着或没有进程判成功，不在关联/发送入口绕开未知请求。
  func confirmSessionEnd(_ session: String) throws {
    try confirmDeliveryResults("""
      mode = 'end' AND targetRef = ?2 AND handledBy IS NOT NULL
        AND status IN ('executing', 'confirming', 'unconfirmed', 'pending') AND r.deadlineAt IS NOT NULL AND (
          EXISTS (SELECT 1 FROM piSessionStates s WHERE s.sessionID = r.targetRef AND s.hostID = r.hostID
            AND s.state = 'ended' AND s.stateSince >= r.deadlineAt - ?3)
          OR EXISTS (SELECT 1 FROM deliveryRequests e WHERE e.targetRef = r.targetRef AND e.hostID = r.hostID
            AND e.mode = 'end' AND e.status = 'succeeded' AND e.completedAt >= r.deadlineAt - ?3))
      """, [session, Int64(DeliveryRequest.phaseLimit * 1_000)])
  }
}
