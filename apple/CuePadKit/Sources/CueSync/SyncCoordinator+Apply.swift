import CloudKit
import Foundation
import os

extension SyncCoordinator {
  func applyFetched(_ modifications: [CKRecord], _ deletions: [(id: CKRecord.ID, recordType: String)]) async throws {
    var changes: [RemoteChange] = []
    for record in modifications where record.recordType != PeerFloor.recordType {  // 门槛不进库，`meet` 看过了
      guard let row = RecordMapper.row(from: record) else {
        report(.unknownType, kind: .incoming, recordType: record.recordType, recordName: record.recordID.recordName)
        continue
      }
      if row.table == .deliveryRequests { traceArrival(of: record, row) }
      changes.append(.save(row, systemFields: RecordMapper.encodeSystemFields(record), serverAt: record.creationDate))
    }
    for (id, recordType) in deletions {
      guard let table = RecordMapper.table(named: recordType) else {
        report(.unknownType, kind: .incoming, recordType: recordType, recordName: id.recordName)
        continue
      }
      changes.append(.delete(SyncKey(table: table, id: id.recordName)))
    }
    for failure in try await store.applyRemote(changes) {
      report(.local, detail: failure.message, kind: .incoming, recordType: nil, recordName: failure.recordName)
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
}
