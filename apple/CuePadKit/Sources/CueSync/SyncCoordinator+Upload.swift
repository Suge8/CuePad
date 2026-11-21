import CloudKit
import CueStore
import CueText
import Foundation

enum Lane: CaseIterable, Sendable {
  case live, bulk

  init(_ table: Table) { self = Table.live[table] == nil ? .bulk : .live }

  var tables: [Table] { Table.synced.filter { Lane($0) == self } }

  var limit: Int { self == .live ? 50 : CloudKitLimits.recordsPerRequest }
}

struct OutgoingBatch: Sendable {
  var saves: [CKRecord]
  var deletes: [CKRecord.ID]
  var drains: (lane: Lane, generation: Int)?
  var stuck: Set<String> = []
  var left: Set<String> = []
  var names: Set<String> { Set(saves.map(\.recordID.recordName) + deletes.map(\.recordName)) }
}

extension SyncCoordinator {
  func nextBatch(
    _ lane: Lane, limit: Int, urgentOnly: Bool = false, wanted: Set<String> = [], excluding inFlight: Set<String> = []
  ) async throws -> OutgoingBatch {
    guard canSync else { throw SyncPaused() }
    var pending: PendingSync, generation: Int
    do {
      try await dropSettledIssues()
      let since = drained[lane]
      if !urgentOnly { drained[lane] = nil }
      (pending, generation) = try await store.pendingSync(since: since, in: lane.tables, urgentOnly: urgentOnly, newestFirst: lane == .live)
      if !wanted.isEmpty {
        let asked = try await store.pendingSync(among: wanted, in: lane.tables)
        pending.saves = (asked.saves + pending.saves).uniqued()
        pending.deletes = (asked.deletes + pending.deletes).uniqued()
      }
    } catch {
      failed(error)
      throw error
    }
    let names = pending.saves.filter { $0.table != .attachments }.map(\.id)
    var deletes = pending.deletes.filter { !fileUploads.contains($0) && !inFlight.contains($0) }
    var batch = OutgoingBatch(saves: [], deletes: [])
    batch.left = inFlight.intersection(names + pending.deletes)
    for name in names where !inFlight.contains(name) {
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
    batch.stuck.formUnion(deletes.filter { unsendable[$0] == .min })
    deletes.removeAll { unsendable[$0] == .min }
    let fits = max(limit - batch.saves.count, 0)
    batch.deletes = deletes.prefix(fits).map(recordID)
    batch.left.formUnion(deletes.dropFirst(fits))
    guard !batch.isEmpty else {
      if !urgentOnly, inFlight.union(fileUploads).isDisjoint(with: pending.saves.map(\.id) + pending.deletes) { drained[lane] = generation }
      return batch
    }
    if !urgentOnly, batch.saves.count + batch.deletes.count + batch.stuck.count == names.count + pending.deletes.count {
      batch.drains = (lane, generation)
    }
    do {
      try await store.noteSent(batch.saves.compactMap { record in
        guard let table = RecordMapper.table(named: record.recordType), let stamp = record.modifiedAt else { return nil }
        return (record.recordID.recordName, table, stamp)
      })
    } catch {
      failed(error)
      throw error
    }
    guard canSync else { throw SyncPaused() }
    return batch
  }

  private func dropSettledIssues() async throws {
    let names = Set(facts.issues.compactMap { $0.kind == .upload ? $0.recordName : nil })
    guard !names.isEmpty else { return }
    let pending = try await store.pendingSync(among: names)
    let settled = names.subtracting(pending.saves.map(\.id) + pending.deletes)
    guard !settled.isEmpty else { return }
    var next = facts
    next.issues.removeAll { $0.kind == .upload && $0.recordName.map(settled.contains) == true }
    if next.status == .failed, !next.issues.contains(where: \.isFailure) { next.status = .idle }
    facts = next
  }

  func reserveForUpload(_ prepared: OutgoingBatch) async throws -> (batch: OutgoingBatch, obsolete: Set<String>) {
    let obsolete = try await store.reserveForUpload(prepared.saves.compactMap { record in
      guard let table = RecordMapper.table(named: record.recordType), let stamp = record.modifiedAt else { return nil }
      return (record.recordID.recordName, table, stamp)
    })
    var batch = prepared
    batch.drop(obsolete)
    return (batch, obsolete)
  }

  func record(for id: CKRecord.ID) async throws -> CKRecord? {
    guard let row = try await store.syncRow(recordName: id.recordName), unsendable[id.recordName] != row.modifiedAt else { return nil }
    let base = try await store.systemFields(of: id.recordName).flatMap(RecordMapper.decodeSystemFields)
    let record = RecordMapper.record(from: row, zoneID: zoneID, base: base)
    if row.table == .attachments {
      guard let key = row.attachmentKey, let file = store.files.fileURL(for: key) else {
        unsendable[id.recordName] = row.modifiedAt
        report(.fileMissing, kind: .upload, recordType: row.table.rawValue, recordName: id.recordName)
        return nil
      }
      record[RecordMapper.fileKey] = CKAsset(fileURL: file)
    }
    return record
  }

  func takeFile(_ name: String) async throws -> CKRecord? {
    guard canSync else { throw SyncPaused() }
    guard fileUploads.insert(name).inserted else { return nil }
    do {
      guard let record = try await record(for: recordID(name)), let stamp = record.modifiedAt else {
        fileUploads.remove(name)
        return nil
      }
      try await store.noteSent([(name, .attachments, stamp)])
      return record
    } catch {
      fileUploads.remove(name)
      throw error
    }
  }

  func filesResumed(_ names: [String]) { fileUploads.formUnion(names) }

  func fileDone(_ name: String) { fileUploads.remove(name) }

  func sent(_ sent: SentRecords, for batch: OutgoingBatch) async -> SendOutcome {
    guard !stopped else { return SendOutcome(progressed: false, paused: true) }
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
    if let drains = batch.drains, received.count == batch.saves.count + batch.deletes.count { drained[drains.lane] = drains.generation }
    var outcome = SendOutcome(progressed: !received.isEmpty)
    try await store.markPushed(sent.saved.compactMap { record in
      RecordMapper.row(from: record).map { ($0, RecordMapper.encodeSystemFields(record), record.creationDate) }
    })
    try await store.dropSyncMetadata(sent.deleted.map(\.recordName))
    if !received.isEmpty {
      facts.issues.removeAll { $0.kind == .upload && $0.recordName.map(received.contains) == true }
      acceptances.yield(())
    }

    for (record, error) in sent.failedSaves {
      let name = record.recordID.recordName
      switch error.code {
      case .serverRecordChanged:
        if let server = error.serverRecord {
          try await applyFetched([server], [])
          outcome.progressed = true
        } else {
          report(.refused, detail: String(localized: "保存冲突但没有服务器版本：\(error.diagnosis)"), kind: .upload, recordType: record.recordType, recordName: name)
        }
      case .batchRequestFailed:
        outcome.progressed = true
      case .unknownItem, .zoneNotFound:
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
    if !received.isEmpty, sent.failedSaves.isEmpty, sent.failedDeletes.isEmpty {
      if status == .quotaExceeded || (status == .failed && !facts.issues.contains(where: \.isFailure)) { facts.status = .idle }
    }
    return outcome
  }

  private func refused(_ fault: SyncFault, _ name: String, version: Int64, _ outcome: inout SendOutcome) {
    guard fault == .rejected else { return outcome.fault = SyncFault.merge(outcome.fault, fault) }
    unsendable[name] = version
    outcome.progressed = true
  }
}

extension CKRecord {
  var modifiedAt: Int64? { (self["modifiedAt"] as? NSNumber)?.int64Value }
}

extension SyncRow {
  var attachmentKey: String? {
    guard table == .attachments, case .text(let hash)? = fields["hash"] else { return nil }
    let format = if case .text(let format)? = fields["format"] { format } else { "" }
    return AttachmentKey.make(hash: hash, format: format)
  }
}

extension Array where Element: Hashable {
  fileprivate func uniqued() -> [Element] {
    var seen = Set<Element>()
    return filter { seen.insert($0).inserted }
  }
}
