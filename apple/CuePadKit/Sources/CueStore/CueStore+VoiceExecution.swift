import Foundation

extension CueStore {
  /// 语音可控范围：Cue 实际接走的本次请求 → 该工具生成的投送 → 会话当前最后一条用户消息。
  /// 混入别的来源的一轮、读过／提到某任务、旧回合和没有真实消息回执的执行都不能授权停止。
  /// 返回仍归属这次请求的实际会话记录，含已歇下的，供界面显示停止后的真实状态。
  public func voiceExecutions(requests: [UUID]) throws -> [PiSessionListItem] {
    guard !requests.isEmpty else { return [] }
    let owned = Set(requests)
    let rows = try select(CueMessage.self, where: """
      EXISTS (SELECT 1 FROM json_each(tools, '$.items') AS item, json_each(item.value, '$.cueRequests') AS request
        WHERE request.value IN (SELECT value FROM json_each(?)))
      """, [JSONColumn.encode(requests)])
    let deliveries = Set(rows.flatMap { row in
      (row.tools?.items ?? []).flatMap { item -> [UUID] in
        let origins = Set(item.cueRequests ?? [])
        guard !item.failed, !origins.isEmpty, origins.isSubset(of: owned) else { return [] }
        return item.deliveries ?? []
      }
    })
    guard !deliveries.isEmpty else { return [] }
    let sessions = try db.query("""
      SELECT DISTINCT p.sessionID FROM piMessages p
      WHERE p.deliveryID IN (SELECT lower(value) FROM json_each(?)) AND p.role IN ('user', 'answer')
        AND NOT EXISTS (SELECT 1 FROM piMessages n WHERE n.sessionID = p.sessionID AND n.role IN ('user', 'answer')
          AND (n.seq > p.seq OR (n.seq = p.seq AND n.id > p.id)))
      """, [JSONColumn.encode(deliveries.sorted { $0.uuidString < $1.uuidString })]) { $0.text(0) }
    let items = try piSessions(sessionIDs: sessions)
    return sessions.sorted().compactMap { items[$0] }
  }

  /// 同一事务核对来源并冻结实际投送身份；这只是入队许可，执行时由 Agent 再核对身份、同步停止。
  /// A、B 即使同属一次通话也各有投送身份，不复用彼此的停止请求。
  public func stopVoiceExecution(_ sessionID: String, requests: [UUID], host: String) throws -> DeliveryRequest {
    try write {
      guard try voiceExecutions(requests: requests).contains(where: { $0.state.sessionID == sessionID }) else {
        throw CueStoreError.cannotStop(sessionID)
      }
      let session = try sessionTarget(sessionID, name: "")
      guard session.state?.canStop == true,
        let delivery = try select(PiChatMessage.self, where: "sessionID = ? AND role IN ('user', 'answer')", [sessionID],
                                  orderBy: "seq DESC, id DESC", limit: 1).first?.deliveryID
      else { throw CueStoreError.cannotStop(sessionID) }
      return try requestControl(.stopTurn, of: session.target, on: session.host(or: host), cue: false, content: delivery.uuidString)
    }
  }
}
