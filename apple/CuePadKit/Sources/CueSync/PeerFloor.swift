import CloudKit
import CueStore
import Foundation

struct PeerFloor {
  static let recordType = "syncFloor"
  static let field = "version"
  let id: CKRecord.ID

  init(zoneID: CKRecordZone.ID) { id = CKRecord.ID(recordName: Self.recordType, zoneID: zoneID) }

  static func version(in records: [CKRecord]) -> Int? {
    records.first { $0.recordType == recordType }.flatMap { ($0[field] as? NSNumber)?.intValue }
  }

  func settle(_ cloud: some ZoneChangeSource & RecordUploader, coordinator: SyncCoordinator) async throws {
    var server: CKRecord?
    do {
      server = try await hedged(after: RequestLimits.hedge) { [id] in try await cloud.records([id]) }.first
    } catch let error as CKError where [.zoneNotFound, .userDeletedZone].contains(error.code) {
      await coordinator.zoneMissing(deletedByUser: error.code == .userDeletedZone)
      guard await coordinator.canSync else { throw SyncPaused() }
      try await cloud.saveZone()
    }
    let required = CueStore.peerFloor
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
