import CloudKit
import CueStore
import Foundation

/// 要上传的一批：从哪些待推送里挑（`BatchScope`）由发送者定，同一条记录同一时刻只在一批里。
struct OutgoingBatch: Sendable {
  var saves: [CKRecord]
  var deletes: [CKRecord.ID]
  /// 交出时库里可传的全在这批里，截至这个同步变更代数：整批收下就记作没有了（`SyncCoordinator.drained`）。
  var drains: Int?
  /// 挑到了、但这一版传不上去的（`SyncCoordinator.unsendable`）：不在批里，马上传那一路据此答没传成。
  var stuck: Set<String> = []
  /// 挑到了、仍待推送但这批装不下的（超过 `limit`）：马上传那一路接着发，不当成已收下。
  var left: Set<String> = []
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
  /// 下一批要上传的：至多 `limit` 条，没有可传的是空批。此刻不能同步（停下了、没有账号）或读库出错时抛出：
  /// 调用方分得清"没有可传的"与"这次准备不了"。后台那一路在上次确定没有可传的之后只看其后的提交碰过的记录（`drained`）；
  /// 马上传那一路只按主键查要的几条：后台那批在路上时 `drained` 是空的，照它就要全量推导。
  func nextBatch(_ scope: BatchScope, limit: Int) async throws -> OutgoingBatch {
    guard canSync else { throw SyncPaused() }
    let pending: PendingSync, generation: Int?, excluded: Set<String>
    do {
      switch scope {
      case .pending(let inFlight):
        let since = drained
        drained = nil
        (pending, generation) = try await store.pendingSync(since: since)
        excluded = inFlight
      case .only(let wanted):
        (pending, generation, excluded) = (try await store.pendingSync(among: wanted), nil, [])
      }
    } catch {
      failed(error)
      throw error
    }
    // 附件记录带着文件，走文件那一路（`FileSender`）；那一路在传的，删除也等它传完
    var names = pending.saves.filter { $0.table != .attachments }.map(\.id)
    var deletes = pending.deletes
    names.removeAll(where: excluded.contains)
    deletes.removeAll { excluded.contains($0) || fileUploads.contains($0) }
    var batch = OutgoingBatch(saves: [], deletes: [])
    for name in names {
      guard batch.saves.count < limit else {
        batch.left.insert(name)
        continue
      }
      let record: CKRecord?
      do { record = try await self.record(for: recordID(name)) } catch {
        failed(error, kind: .upload, recordName: name)
        throw error
      }
      if let record { batch.saves.append(record) } else if unsendable[name] != nil { batch.stuck.insert(name) }
    }
    // 删除只认删除被拒记下的 `.min`：先前哪一版保存被拒，不挡之后删掉它
    batch.stuck.formUnion(deletes.filter { unsendable[$0] == .min })
    deletes.removeAll { unsendable[$0] == .min }
    let fits = max(limit - batch.saves.count, 0)
    batch.deletes = deletes.prefix(fits).map(recordID)
    batch.left.formUnion(deletes.dropFirst(fits))
    let all = pending.saves.count(where: { $0.table != .attachments }) + pending.deletes.count
    guard !batch.isEmpty else {
      if case .pending = scope, excluded.union(fileUploads).isDisjoint(with: pending.saves.map(\.id) + pending.deletes) { drained = generation }
      return batch
    }
    // 这一版传不上去的同不可传的一样不算剩下：改过才再出现在提交的增量里
    if case .pending = scope, batch.saves.count + batch.deletes.count + batch.stuck.count == all { batch.drains = generation }
    do {
      try await store.noteSent(batch.saves.compactMap { record in
        guard let table = RecordMapper.table(named: record.recordType), let stamp = record.modifiedAt else { return nil }
        return (record.recordID.recordName, table, stamp)
      })
    } catch {
      failed(error)
      throw error
    }
    // 构造这批时可能停下了（拉到过高的门槛、要你决定）：停下后不再交出新的一批
    guard canSync else { throw SyncPaused() }
    return batch
  }

  /// 构造要上传的记录：以上次服务器记录的系统字段为底，写入当前行的字段。行已不在、这一版传不上去（`unsendable`）时为 nil；
  /// 附件的文件不在本机的这一版记进 `unsendable` 并报告。读库出错抛出。
  func record(for id: CKRecord.ID) async throws -> CKRecord? {
    guard let row = try await store.syncRow(recordName: id.recordName), unsendable[id.recordName] != row.modifiedAt else { return nil }
    let base = try await store.systemFields(of: id.recordName).flatMap(RecordMapper.decodeSystemFields)
    let record = RecordMapper.record(from: row, zoneID: zoneID, base: base)
    if row.table == .attachments {
      guard let key = row.attachmentKey, let file = store.files.fileURL(forKey: key) else {
        unsendable[id.recordName] = row.modifiedAt
        report(.fileMissing, kind: .upload, recordType: row.table.rawValue, recordName: id.recordName)
        return nil
      }
      record[RecordMapper.fileKey] = CKAsset(fileURL: file)
    }
    return record
  }

  /// 文件那一路要传这条附件记录：带上文件、记下交出的版本，在传完（`fileDone`）之前后台那一路不删它、这一路不再交出。
  /// 已在传、传不上去（文件不在本机、这一版被拒过）为 nil。读库出错抛出。
  func takeFile(_ name: String) async throws -> CKRecord? {
    guard canSync else { throw SyncPaused() }
    guard !fileUploads.contains(name), let record = try await record(for: recordID(name)), let stamp = record.modifiedAt else { return nil }
    try await store.noteSent([(name, .attachments, stamp)])
    fileUploads.insert(name)
    return record
  }

  /// 接上的上一个进程交给系统的上传（`FileSender.resume`）：同 `takeFile` 交出的，传完之前不删、不另传。
  func filesResumed(_ names: [String]) { fileUploads.formUnion(names) }

  func fileDone(_ name: String) { fileUploads.remove(name) }

  /// 一批上传的结果：记账，告诉发送者这批有没有进展、该等什么。有记录收下就是一次成功（`succeeded`），并告诉实时层（`acceptances`）。
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
      acceptances.yield(())
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
          report(.refused, detail: String(localized: "保存冲突但没有服务器版本：\(error.diagnosis)"), kind: .upload, recordType: record.recordType, recordName: name)
        }
      case .batchRequestFailed:
        outcome.progressed = true  // 同批里别的记录被拒，这条自己没问题
      case .unknownItem, .zoneNotFound:
        // 服务器上没有这条记录（或整个同步区没了）：忘掉旧系统字段，作为新记录重新上传
        if error.code == .zoneNotFound { outcome.zoneMissing = true }
        try await store.dropSyncMetadata([name])
        outcome.progressed = true
      default:
        refused(failed(error, kind: .upload, recordType: record.recordType, recordName: name), name, version: record.modifiedAt ?? .min, &outcome)
      }
    }
    for (id, error) in sent.failedDeletes {
      switch error.code {
      case .unknownItem, .zoneNotFound:
        try await store.dropSyncMetadata([id.recordName])
        outcome.progressed = true
      case .batchRequestFailed: outcome.progressed = true
      default: refused(failed(error, kind: .upload, recordName: id.recordName), id.recordName, version: .min, &outcome)
      }
    }
    // 收下了：之前的失败与空间不足都过去了
    if !received.isEmpty, sent.failedSaves.isEmpty, sent.failedDeletes.isEmpty {
      if status == .quotaExceeded || (status == .failed && !facts.issues.contains(where: \.isFailure)) { facts.status = .idle }
    }
    return outcome
  }

  /// 一条被拒：服务器拒收这一版（`SyncFault.rejected`）的记进 `unsendable`、跳过它接着发别的，改过再试；
  /// 其余（连不上、要等、账号）是整个发送者的事，合进这批的结局。删除没有版本，记 `.min`。
  private func refused(_ fault: SyncFault, _ name: String, version: Int64, _ outcome: inout SendOutcome) {
    guard fault == .rejected else { return outcome.fault = SyncFault.merge(outcome.fault, fault) }
    unsendable[name] = version
    outcome.progressed = true
  }
}

extension CKRecord {
  /// 记录的版本（同步表的 `modifiedAt` 列）。
  var modifiedAt: Int64? { (self["modifiedAt"] as? NSNumber)?.int64Value }
}

extension SyncRow {
  /// 附件记录的 key（`AttachmentFiles.key`）；不是附件记录为 nil。
  var attachmentKey: String? {
    guard table == .attachments, case .text(let hash)? = fields["hash"] else { return nil }
    let format = if case .text(let format)? = fields["format"] { format } else { "" }
    return AttachmentFiles.key(hash: hash, format: format)
  }
}
