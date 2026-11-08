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

  /// 从真实请求归属与最新消息派生可停止目标；缺少回合或本次启动证明时不授予权限。
  public func voiceExecutionTarget(_ sessionID: String, requests: [UUID], turnStartedAt: Date? = nil) throws -> PiTurnTarget {
    guard let state = try voiceExecutions(requests: requests).first(where: { $0.state.sessionID == sessionID })?.state,
      state.canStop, let boot = state.bootID, let turn = turnStartedAt ?? state.turnStartedAt,
      let delivery = try select(PiChatMessage.self, where: "sessionID = ? AND role IN ('user', 'answer')", [sessionID],
                                orderBy: "seq DESC, id DESC", limit: 1).first?.deliveryID
    else { throw CueStoreError.cannotStop(sessionID) }
    return PiTurnTarget(hostID: state.hostID, bootID: boot, sessionID: sessionID, deliveryID: delivery, turnStartedAtMilliseconds: turn.stored)
  }

  /// 本机界面点击时冻结目标；远端命令必须使用带完整 expected 的入口，不能按手机的 sessionID 重新选当前轮。
  public func stopVoiceExecution(_ sessionID: String, requests: [UUID], host: String) throws -> DeliveryRequest {
    try write {
      let expected = try voiceExecutionTarget(sessionID, requests: requests)
      guard expected.hostID == host else { throw CueStoreError.cannotStop(sessionID) }
      return try putVoiceStop(expected, requests: requests, command: nil)
    }
  }

  /// 入队与来源/回合复核在同一事务；执行器、Agent 接收端还要重验，不能把队列时延当作停止后来工作的许可。
  public func stopVoiceExecution(_ expected: PiTurnTarget, requests: [UUID], command: UUID? = nil) throws -> DeliveryRequest {
    try write { try putVoiceStop(expected, requests: requests, command: command) }
  }

  /// 两个公开入口各自持有一层事务；目标校验与入队共用这个不另开事务的实现。
  private func putVoiceStop(_ expected: PiTurnTarget, requests: [UUID], command: UUID?) throws -> DeliveryRequest {
    if let command, let existing = try deliveryRequest(command) {
      guard existing.stopTurn == expected else { throw CueStoreError.cannotStop(expected.sessionID) }
      return existing
    }
    // 回合时间来自 Mac 活连接，不使用可能仍在节流中的同步记录授权；这里复核原请求、投送、所在 Mac 与启动身份。
    // 排队期间是否已换回合，由 MacExecutor 和 Agent 各自面对实时状态核对。
    let origin = try voiceExecutionTarget(expected.sessionID, requests: requests, turnStartedAt: Date(timeIntervalSince1970: Double(expected.turnStartedAtMilliseconds) / 1000))
    guard origin == expected else {
      throw CueStoreError.cannotStop(expected.sessionID)
    }
    let session = try sessionTarget(expected.sessionID, name: "")
    if let command {
      return try insertDelivery(expected.content, to: session.target, on: expected.hostID, mode: .stopTurn, cue: false, id: command)
    }
    return try requestControl(.stopTurn, of: session.target, on: expected.hostID, cue: false, content: expected.content)
  }
}
