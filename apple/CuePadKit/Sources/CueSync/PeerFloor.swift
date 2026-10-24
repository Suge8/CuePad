import CloudKit
import CueStore
import Foundation

/// 最低对端版本：跨版本兼容只有这一个门槛。同步区里一条记录，值是结构版本；结构版本低于它的设备停下同步、请你更新
/// （`SyncStatus.outdated`），本机内容照用、改动留着，更新后接着传。
///
/// 这台要求的门槛就是它能打开的最老库（`CueStore.supportedSchemaVersions` 的下界，即 `Schema.baseVersion`），能同步到的是它自己的
/// 结构版本（上界）：起点上调时，给更早设备留的兼容（升级步骤、同步落库的补丁、读取的缺省值）一起删。
/// 只升不降：开始上传前读一次（`settle`），低于这台要求的才写，并发写被拒就按服务器的那条重来；运行中别的设备抬上去的，拉取时碰到
/// （`SyncCoordinator.meet`）。门槛不进库，每次开始同步都从云端读。
/// 这之前发出的版本不认这条记录，只当未知类型跳过：门槛只拦得住认它的版本。
struct PeerFloor {
  static let recordType = "syncFloor"
  static let field = "version"
  let id: CKRecord.ID

  init(zoneID: CKRecordZone.ID) { id = CKRecord.ID(recordName: Self.recordType, zoneID: zoneID) }

  static func version(in records: [CKRecord]) -> Int? {
    records.first { $0.recordType == recordType }.flatMap { ($0[field] as? NSNumber)?.intValue }
  }

  /// 开始上传前对门槛：云端的高于这台能同步的就停下（抛 `SyncPaused`）；低于这台要求的抬上去，抬完才返回。
  func settle(_ cloud: some ZoneChangeSource & RecordUploader, coordinator: SyncCoordinator) async throws {
    var server: CKRecord?
    do {
      server = try await hedged(after: RequestLimits.hedge) { [id] in try await cloud.records([id]) }.first
    } catch let error as CKError where [.zoneNotFound, .userDeletedZone].contains(error.code) {
      await coordinator.zoneMissing(deletedByUser: error.code == .userDeletedZone)
      guard await coordinator.canSync else { throw SyncPaused() }
      try await cloud.saveZone()
    }
    let required = CueStore.supportedSchemaVersions.lowerBound
    while true {
      let found = server.map { [$0] } ?? []
      try await coordinator.meet(found)
      if let version = Self.version(in: found), version >= required { return }
      let record = server ?? CKRecord(recordType: Self.recordType, recordID: id)
      record[Self.field] = required as NSNumber
      guard let (_, error) = try await cloud.upload(saving: [record], deleting: []).failedSaves.first else { return }
      guard error.code == .serverRecordChanged, let newer = error.serverRecord else { throw error }
      server = newer
    }
  }
}
