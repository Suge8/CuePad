import CloudKit
import Foundation
import os

extension SyncCoordinator {
  func applyFetched(_ modifications: [CKRecord], _ deletions: [(id: CKRecord.ID, recordType: String)]) async throws {
    var changes: [RemoteChange] = []
    for record in modifications where record.recordType != PeerFloor.recordType {  // 门槛不进库，`meet` 看过了
      guard let row = RecordMapper.row(from: record) else {
        report("未知的记录类型「\(record.recordType)」，已跳过（可能来自更新版本的 CuePad）", kind: .incoming, recordType: record.recordType, recordName: record.recordID.recordName)
        continue
      }
      if row.table == .deliveryRequests { traceArrival(of: record, row) }
      if row.table == .attachments, try !adoptAsset(of: record, row) { continue }
      changes.append(.save(row, systemFields: RecordMapper.encodeSystemFields(record)))
    }
    for (id, recordType) in deletions {
      guard let table = RecordMapper.table(named: recordType) else {
        report("未知的记录类型「\(recordType)」的删除，已跳过", kind: .incoming, recordType: recordType, recordName: id.recordName)
        continue
      }
      changes.append(.delete(SyncKey(table: table, id: id.recordName)))
    }
    for failure in try await store.applyRemote(changes) {
      report(failure.message, kind: .incoming, recordType: nil, recordName: failure.recordName)
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
      report("附件记录没有文件，已拒绝", kind: .incoming, recordType: record.recordType, recordName: name)
      return false
    }
    do {
      try store.files.adopt(fileAt: file, hash: hash)
      return true
    } catch let error as CueStoreError where [.invalidAttachmentHash, .attachmentHashMismatch].contains(error) {
      report("附件文件校验失败，已拒绝：\(error)", kind: .incoming, recordType: record.recordType, recordName: name)
      return false
    }
  }
}
