import CloudKit
import Foundation
import os

extension SyncCoordinator {
  func applyFetched(_ modifications: [CKRecord], _ deletions: [(id: CKRecord.ID, recordType: String)]) async throws {
    var changes: [RemoteChange] = []
    for record in modifications where record.recordType != PeerFloor.recordType {  // 门槛不进库，`meet` 看过了
      guard let row = RecordMapper.row(from: record) else {
        report("未知的记录类型「\(record.recordType)」，已跳过（可能来自更新版本的 CuePad）", recordType: record.recordType, recordName: record.recordID.recordName)
        continue
      }
      if row.table == .deliveryRequests { traceArrival(of: record, row) }
      if row.table == .attachments, try !adoptAsset(of: record, row) { continue }
      changes.append(.save(row, systemFields: RecordMapper.encodeSystemFields(record)))
    }
    for (id, recordType) in deletions {
      guard let table = RecordMapper.table(named: recordType) else {
        report("未知的记录类型「\(recordType)」的删除，已跳过", recordType: recordType, recordName: id.recordName)
        continue
      }
      changes.append(.delete(SyncKey(table: table, id: id.recordName)))
    }
    for failure in try await store.applyRemote(changes) {
      report(failure.message, recordType: nil, recordName: failure.recordName)
    }
  }

  /// 投送请求（及其结果）到达的时间线：创建 → 服务器（对端上传用了多久）→ 本机（拉取用了多久）。
  private func traceArrival(of record: CKRecord, _ row: SyncRow) {
    guard case .int(let created)? = row.fields["createdAt"], case .text(let status)? = row.fields["status"],
      let stored = record.modificationDate
    else { return }
    let toServer = stored.timeIntervalSince(Date(timeIntervalSince1970: Double(created) / 1000))
    Self.log.info(
      "投送请求到达 \(record.recordID.recordName.prefix(8), privacy: .public) \(status, privacy: .public)：创建后 \(toServer, format: .fixed(precision: 1)) 秒到服务器，再 \(Date.now.timeIntervalSince(stored), format: .fixed(precision: 1)) 秒到本机")
  }

  /// 附件记录必须带文件且内容与哈希一致，才把文件放进附件目录；记录本身坏了拒绝这条记录并报告（返回 false）。
  /// 本机写不进去（读下载的文件、建目录、拷贝、改名失败）抛出：这一页没应用完，拉取器不前移令牌，之后再拉。
  private func adoptAsset(of record: CKRecord, _ row: SyncRow) throws -> Bool {
    let name = record.recordID.recordName
    guard case .text(let hash)? = row.fields["hash"], let file = (record["file"] as? CKAsset)?.fileURL else {
      report("附件记录没有文件，已拒绝", recordType: record.recordType, recordName: name)
      return false
    }
    do {
      try store.files.adopt(fileAt: file, hash: hash)
      return true
    } catch let error as CueStoreError where [.invalidAttachmentHash, .attachmentHashMismatch].contains(error) {
      report("附件文件校验失败，已拒绝：\(error)", recordType: record.recordType, recordName: name)
      return false
    }
  }

  // MARK: 发送结果

  func processSent(_ sent: SentRecords) async throws -> SendOutcome {
    if let drained, let count = drained.sending {
      self.drained = sent.saved.count + sent.deleted.count == count ? (drained.generation, nil) : nil
    }
    var outcome = SendOutcome(progressed: !sent.saved.isEmpty || !sent.deleted.isEmpty, blocked: false, zoneMissing: false)
    try await store.markPushed(sent.saved.compactMap { record in RecordMapper.row(from: record).map { ($0, RecordMapper.encodeSystemFields(record)) } })
    try await store.dropSyncMetadata(sent.deleted.map(\.recordName))

    // 没收下的仍是待推送（库里推导），下一批自然带上；这里只处理要先改本机状态才能成功的
    for (record, error) in sent.failedSaves {
      let name = record.recordID.recordName
      switch error.code {
      case .serverRecordChanged:
        if let server = error.serverRecord {
          try await applyFetched([server], [])  // 带上服务器的版本标签；本机版本胜出的话下一批重传
          outcome.progressed = true
        } else {
          report("保存冲突但没有服务器版本：\(error)", recordType: record.recordType, recordName: name)
        }
      case .batchRequestFailed:
        outcome.progressed = true  // 同批里别的记录被拒，这条自己没问题
      case .unknownItem, .zoneNotFound:
        // 服务器上没有这条记录（或整个同步区没了）：忘掉旧系统字段，作为新记录重新上传
        if error.code == .zoneNotFound { outcome.zoneMissing = true }
        try await store.dropSyncMetadata([name])
        outcome.progressed = true
      default:
        outcome.blocked = classify(error, recordType: record.recordType, recordName: name) || outcome.blocked
        outcome.wait(for: error)
      }
    }
    for (id, error) in sent.failedDeletes {
      switch error.code {
      case .unknownItem, .zoneNotFound:
        try await store.dropSyncMetadata([id.recordName])
        outcome.progressed = true
      case .batchRequestFailed: outcome.progressed = true
      default:
        outcome.blocked = classify(error, recordName: id.recordName) || outcome.blocked
        outcome.wait(for: error)
      }
    }
    // 收下了：之前的失败与空间不足都过去了
    if !sent.saved.isEmpty || !sent.deleted.isEmpty, sent.failedSaves.isEmpty, sent.failedDeletes.isEmpty, status.isSettledFailure {
      facts.status = .idle
    }
    return outcome
  }

  /// 连不上 iCloud 的错误码：显示离线（`reached`），发送者退避重试（`RecordSender.retryable`）。
  static let offlineCodes: Set<CKError.Code> = [.networkFailure, .networkUnavailable, .serviceUnavailable, .serverResponseLost]

  /// 把 CloudKit 错误映射到状态。返回 true 表示这类失败不应立刻重试。瞬时网络类错误由发送者退避重试（RecordSender）。
  @discardableResult
  func classify(_ error: CKError, recordType: String? = nil, recordName: String?) -> Bool {
    guard !stopped else { return true }
    switch error.code {
    case .quotaExceeded:
      facts.status = .quotaExceeded
      return true
    case .notAuthenticated:
      facts.status = .noAccount
      return true
    case let code where Self.offlineCodes.contains(code):
      reached(error)
      return false
    case .zoneBusy, .requestRateLimited, .operationCancelled, .accountTemporarilyUnavailable, .limitExceeded:
      return false
    default:
      report(error, recordType: recordType, recordName: recordName)
      return true
    }
  }

  /// 一次拉取或上传的结果（nil 是成功）：网络类失败时连不上 iCloud（`SyncStatus.offline`），之后任何一次成功回到空闲。
  /// 只在正常状态之间切换：账号、配额、要你决定这些更要紧的状态不被它盖过。
  func reached(_ error: (any Error)?) {
    if let error {
      guard Self.isOffline(error), status == .idle || status == .starting else { return }
      facts.status = .offline
    } else if status == .offline {
      facts.status = .idle
    }
  }

  private static func isOffline(_ error: any Error) -> Bool {
    guard let error = error as? CKError else { return error is URLError }
    guard error.code == .partialFailure else { return offlineCodes.contains(error.code) }
    return error.partialErrorsByItemID?.values.contains { isOffline($0) } ?? false
  }

  // MARK: 报告

  func report(_ error: Error, recordType: String? = nil, recordName: String?) {
    report(error.diagnosis, recordType: recordType, recordName: recordName, failed: true)
  }

  func report(_ message: String, recordType: String?, recordName: String?, failed: Bool = false) {
    var next = facts
    let issue = SyncIssue(recordType: recordType, recordName: recordName, message: message)
    // 停下后每次重试都会再报同一个错：问题列表里已有的不再加，免得被它刷满
    if !next.issues.contains(issue) { next.issues.append(issue) }
    if next.issues.count > Self.issueLimit { next.issues.removeFirst(next.issues.count - Self.issueLimit) }
    if failed, !stopped { next.status = .failed(message) }
    facts = next  // 问题与状态一次送达
  }
}

extension SyncStatus {
  /// 一次成功的上传就能清掉的状态。
  fileprivate var isSettledFailure: Bool {
    switch self {
    case .failed, .quotaExceeded: true
    default: false
    }
  }
}

extension SendOutcome {
  /// 这条被拒的原因是可重试的（限流、服务忙等）：记下要等，取服务器给的最长等待。
  fileprivate mutating func wait(for error: CKError) {
    guard RecordSender.retryable.contains(error.code) else { return }
    let given = error.retryAfterSeconds.map { Duration.seconds($0) }
    switch throttled {
    case nil: throttled = .some(given)
    case .some(let current): throttled = .some([current, given].compactMap { $0 }.max())
    }
  }
}
