import Foundation

extension CueStore {
  func pendingDeliveries(for host: String) throws -> [DeliveryRequest] {
    try select(
      DeliveryRequest.self, where: "status = '\(DeliveryStatus.pending.rawValue)' AND handledBy IS NULL AND hostID = ?", [host],
      orderBy: "createdAt, rowid")
  }

  /// 附件准备也有自己的期限；同一 pending 阶段只写一次。
  func prepareDelivery(_ id: UUID, until deadline: Date) throws -> DeliveryRequest? {
    try write {
      try db.run(
        "UPDATE deliveryRequests SET deadlineAt = ?, modifiedAt = MAX(modifiedAt + 1, ?) WHERE id = ? AND status = 'pending' AND handledBy IS NULL AND deadlineAt IS NULL",
        [deadline, Date.stamp, id])
      let current = try find(DeliveryRequest.self, id)
      return current?.isWithdrawable == true ? current : nil
    }
  }

  /// 领取与执行期限原子写入；只有这次领取可以交给 handler。
  func claimDelivery(_ id: UUID, host: String, until deadline: Date) throws -> DeliveryRequest? {
    try write {
      try db.run(
        "UPDATE deliveryRequests SET status = 'executing', handledBy = ?, deadlineAt = ?, modifiedAt = MAX(modifiedAt + 1, ?) WHERE id = ? AND status = 'pending' AND handledBy IS NULL",
        [host, deadline, Date.stamp, id])
      return db.changes > 0 ? try find(DeliveryRequest.self, id) : nil
    }
  }

  /// 写回结果：失败的原因随 `DeliveryOutcome.failed` 一起来，没有不带原因的失败。
  /// 只改还没有结果的（放弃的是待领取的、执行的是执行中的），不覆盖已经写下的结果。
  /// 任务的状态与正文都不因说话而变：发出的正文留在任务上，"发过没有"看投送请求。
  /// 你的作答成功了，同一个事务里往那个会话的对话写下你答了什么（`PiChatRole.answer`；Cue 替你答的不写，记在它那一轮的经过里）。
  func finishDelivery(_ request: DeliveryRequest, _ outcome: DeliveryOutcome, at completed: Date) throws -> Bool {
    let id = request.id
    let (status, reason): (DeliveryStatus, ShownText?) =
      switch outcome {
      case .succeeded: (.succeeded, nil)
      case .confirming where request.deadlineAt.map({ completed < $0 }) != true:
        (.unconfirmed, Speech.unconfirmedReason)
      case .confirming: (.confirming, nil)
      case .failed(let reason): (.failed, reason)
      case .unconfirmed(let reason): (.unconfirmed, reason)
      }
    let deadline = status == .confirming ? completed.addingTimeInterval(Speech.receiptLimit) : request.deadlineAt
    return try write {
      try db.run(
        """
        UPDATE deliveryRequests SET status = ?, failure = ?, completedAt = ?, deadlineAt = ?, modifiedAt = MAX(modifiedAt + 1, ?)
        WHERE id = ? AND status = ? AND status != ?
        """, [status.rawValue, reason?.stored, status == .confirming ? nil as Date? : completed, deadline, Date.stamp, id, request.status.rawValue, status.rawValue])
      let changed = db.changes > 0
      guard changed, status == .succeeded, let request = try find(DeliveryRequest.self, id), !request.isFromCue,
        let answer = request.answer, let session = request.target.ref
      else { return changed }
      // 排在会话文件里此刻最后一条之后（作答时 Agent 停着等你，接下来的都在它之后）；对话按 `at` 把它插到答的那一刻：
      // 你写下作答请求的时刻，不是这里执行完的时刻（离线答的、Mac 晚领取的，执行晚于答）
      let seq = try db.first("SELECT MAX(seq) FROM piMessages WHERE sessionID = ?", [session]) { $0.isNull(0) ? 0 : $0.int(0) } ?? 0
      _ = try insert(
        PiChatMessage(
          sessionID: session, entryID: "answer/\(id.uuidString.lowercased())", seq: seq, role: .answer, text: answer.value.said, at: request.createdAt,
          deliveryID: id, question: answer.question, shownText: answer.value.shown),
        ignoringExisting: true)
      return changed
    }
  }

  /// 重开只恢复核对，绝不把领取事实退回 pending；旧记录没有期限，也不补造一段新等待。
  func unsettledDeliveries(for host: String) throws -> [DeliveryRequest] {
    try select(
      DeliveryRequest.self,
      where: "hostID = ? AND (status IN ('executing', 'confirming', 'unconfirmed') OR (status = 'pending' AND handledBy IS NOT NULL))", [host])
  }

  /// 删除完成时间早于 `cutoff` 的请求；返回是否还剩已完成的（还剩就再排一轮）。
  /// 带着灵感或任务、已成功的开新会话请求在被认领前留着（会话记录可能晚到，认领靠它，见 `claimLaunchedCards`），
  /// 最多等到完成时间早于 `claimCutoff`（会话记录始终没到）；认领了、失败了、或之后又交给了别处（不会再被认领）就按保留期清理。
  /// 发出的话（`send`）不按保留期清：送到的等它在对话里的那条消息上了服务器再收走（`markPushed`），气泡才不会在消息到别的设备之前没了；
  /// 没能送达的留着等用户重发或移除（重发写成后移除它）。Cue 发起的请求失败了留着给 Cue 醒来时看（`cueChanges`）。
  /// 这几种都至多留到完成早于 `keptCutoff`。
  func deleteCompletedDeliveries(before cutoff: Date, claimCutoff: Date, keptCutoff: Date) throws -> Bool {
    let done = "status IN ('\(DeliveryStatus.succeeded.rawValue)', '\(DeliveryStatus.failed.rawValue)')"
    let kept = """
      completedAt >= ?3 AND (mode = '\(DeliveryMode.send.rawValue)' OR (status = '\(DeliveryStatus.failed.rawValue)' AND origin IS '\(DeliveryOrigin.cue.rawValue)'))
      """
    let awaitingClaim = """
      mode = 'start' AND status = '\(DeliveryStatus.succeeded.rawValue)' AND cardID IS NOT NULL AND completedAt >= ?2
        AND \(Self.latestHandoff("deliveryRequests")) AND \(Self.launchUnclaimed)
      """
    let arguments: [any SQLBindable] = [cutoff, claimCutoff, keptCutoff]
    return try write {
      try db.run(
        "DELETE FROM deliveryRequests WHERE \(done) AND completedAt < ?1 AND NOT (\(awaitingClaim)) AND NOT (\(kept))",
        arguments)
      return try db.first("SELECT 1 FROM deliveryRequests WHERE \(done) AND NOT (\(kept))", arguments) { _ in true } != nil
    }
  }
}
