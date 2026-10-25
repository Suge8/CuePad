import CloudKit
import CueStore
import Foundation

/// 要上传的一批：从哪些待推送里挑（`BatchScope`）由发送者定，同一条记录同一时刻只在一批里。
struct OutgoingBatch: Sendable {
  var saves: [CKRecord]
  var deletes: [CKRecord.ID]
  /// 交出时库里可传的全在这批里，截至这个同步变更代数：整批收下就记作没有了（`SyncCoordinator.drained`）。
  var drains: Int?
  var names: Set<String> { Set(saves.map(\.recordID.recordName) + deletes.map(\.recordName)) }
}

/// 一批从哪些待推送里挑。
enum BatchScope: Sendable {
  /// 后台那一路：全部待推送，跳过在路上的（另一批里的不重发同一条）。
  case pending(excluding: Set<String>)
  /// 马上传的那一路：只要这几条里还待推送的。
  case only(Set<String>)
}

extension SyncCoordinator {
  /// 下一批要上传的：至多 `limit` 条；没有可传的（或此刻不能同步）为 nil。后台那一路在上次确定没有可传的之后只看其后的提交碰过的记录（`drained`）。
  func nextBatch(_ scope: BatchScope, limit: Int) async -> OutgoingBatch? {
    guard canSync else { return nil }
    let since = drained
    if case .pending = scope { drained = nil }
    let pending: PendingSync, generation: Int
    do { (pending, generation) = try await store.pendingSync(since: since) } catch {
      failed(error)
      return nil
    }
    let excluded: Set<String>
    var names = pending.saves.map(\.id).filter { unsendable[$0] == nil }
    var deletes = pending.deletes
    switch scope {
    case .pending(let inFlight):
      excluded = inFlight
      names.removeAll(where: inFlight.contains)
      deletes.removeAll(where: inFlight.contains)
    case .only(let wanted):
      excluded = []
      names.removeAll { !wanted.contains($0) }
      deletes.removeAll { !wanted.contains($0) }
    }
    var saves: [CKRecord] = []
    for name in names where saves.count < limit {
      if let record = await record(for: recordID(name)) { saves.append(record) }
    }
    let all = pending.saves.count + pending.deletes.count
    var batch = OutgoingBatch(saves: saves, deletes: Array(deletes.prefix(limit - saves.count)).map(recordID))
    guard !batch.saves.isEmpty || !batch.deletes.isEmpty else {
      if case .pending = scope, excluded.isDisjoint(with: pending.saves.map(\.id) + pending.deletes) { drained = generation }
      return nil
    }
    // 构造不出来的（附件文件不在本机）记进了 `unsendable`，同不可传的一样不算剩下
    if case .pending = scope, saves.count + batch.deletes.count + pending.saves.count(where: { unsendable[$0.id] != nil }) == all {
      batch.drains = generation
    }
    do {
      try await store.noteSent(saves.compactMap { record in
        guard let table = RecordMapper.table(named: record.recordType), let stamp = (record["modifiedAt"] as? NSNumber)?.int64Value else { return nil }
        return (record.recordID.recordName, table, stamp)
      })
    } catch {
      failed(error)
      return nil
    }
    // 构造这批时可能停下了（拉到过高的门槛、要你决定）：停下后不再交出新的一批
    guard canSync else { return nil }
    return batch
  }

  /// 构造要上传的记录：以上次服务器记录的系统字段为底，写入当前行的字段；行已不在则返回 nil。
  func record(for id: CKRecord.ID) async -> CKRecord? {
    do {
      guard let row = try await store.syncRow(recordName: id.recordName) else { return nil }
      let base = try await store.systemFields(of: id.recordName).flatMap(RecordMapper.decodeSystemFields)
      let record = RecordMapper.record(from: row, zoneID: zoneID, base: base)
      if row.table == .attachments {
        guard case .text(let hash)? = row.fields["hash"], let file = store.files.fileURL(for: hash) else {
          unsendable[id.recordName] = row.modifiedAt
          report(.fileMissing, kind: .upload, recordType: row.table.rawValue, recordName: id.recordName)
          return nil
        }
        record["file"] = CKAsset(fileURL: file)
      }
      return record
    } catch {
      failed(error, kind: .upload, recordName: id.recordName)
      return nil
    }
  }

  /// 一批上传的结果：记账，告诉发送者这批有没有进展、该等什么。有记录收下就是一次成功（`succeeded`），并告诉实时层（`acceptedUpdates`）。
  func sent(_ sent: SentRecords, for batch: OutgoingBatch) async -> SendOutcome {
    guard !stopped else { return SendOutcome(progressed: false, fault: .rejected) }
    // 服务器答了才是连上了：有记录收下，或逐条的拒绝里有不是连不上的（版本冲突、限流）；全是连不上的不算
    let failures = sent.failedSaves.map(\.error) + sent.failedDeletes.map(\.error)
    if !sent.saved.isEmpty || !sent.deleted.isEmpty || failures.contains(where: { !SyncFault($0).isOffline }) { succeeded() }
    do {
      return try await processSent(sent, for: batch)
    } catch {
      return SendOutcome(progressed: false, fault: failed(error))
    }
  }

  private func processSent(_ sent: SentRecords, for batch: OutgoingBatch) async throws -> SendOutcome {
    let received = Set(sent.saved.map(\.recordID.recordName) + sent.deleted.map(\.recordName))
    if let generation = batch.drains, received.count == batch.saves.count + batch.deletes.count { drained = generation }
    var outcome = SendOutcome(progressed: !received.isEmpty)
    try await store.markPushed(sent.saved.compactMap { record in RecordMapper.row(from: record).map { ($0, RecordMapper.encodeSystemFields(record)) } })
    try await store.dropSyncMetadata(sent.deleted.map(\.recordName))
    if !received.isEmpty {
      facts.issues.removeAll { $0.kind == .upload && $0.recordName.map(received.contains) == true }
      accepted(AcceptedChanges(tables: Set(sent.saved.compactMap { RecordMapper.table(named: $0.recordType) }), saved: sent.saved.count, deleted: sent.deleted.count))
    }

    // 没收下的仍是待推送（库里推导），下一批自然带上；这里只处理要先改本机状态才能成功的
    for (record, error) in sent.failedSaves {
      let name = record.recordID.recordName
      switch error.code {
      case .serverRecordChanged:
        if let server = error.serverRecord {
          try await applyFetched([server], [])  // 带上服务器的版本标签；本机版本胜出的话下一批重传
          outcome.progressed = true
        } else {
          report(.refused, detail: "保存冲突但没有服务器版本：\(error.diagnosis)", kind: .upload, recordType: record.recordType, recordName: name)
        }
      case .batchRequestFailed:
        outcome.progressed = true  // 同批里别的记录被拒，这条自己没问题
      case .unknownItem, .zoneNotFound:
        // 服务器上没有这条记录（或整个同步区没了）：忘掉旧系统字段，作为新记录重新上传
        if error.code == .zoneNotFound { outcome.zoneMissing = true }
        try await store.dropSyncMetadata([name])
        outcome.progressed = true
      default:
        outcome.fault = SyncFault.merge(outcome.fault, failed(error, kind: .upload, recordType: record.recordType, recordName: name))
      }
    }
    for (id, error) in sent.failedDeletes {
      switch error.code {
      case .unknownItem, .zoneNotFound:
        try await store.dropSyncMetadata([id.recordName])
        outcome.progressed = true
      case .batchRequestFailed: outcome.progressed = true
      default: outcome.fault = SyncFault.merge(outcome.fault, failed(error, kind: .upload, recordName: id.recordName))
      }
    }
    // 收下了：之前的失败与空间不足都过去了
    if !received.isEmpty, sent.failedSaves.isEmpty, sent.failedDeletes.isEmpty {
      if status == .quotaExceeded || (status == .failed && !facts.issues.contains(where: \.isFailure)) { facts.status = .idle }
    }
    return outcome
  }
}
