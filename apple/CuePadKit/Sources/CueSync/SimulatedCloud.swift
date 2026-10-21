import CloudKit
import CueStore
import Foundation
import os

/// 内存里的 iCloud 替身：账号总是可用，同步区是一组按写入先后编号的记录，令牌就是编号；收下的上传照单记下（`saved`）。
/// 测试与调试画面用它跑真实的同步代码（`CloudSync`），只换掉网络那一头。
actor SimulatedCloud: SyncCloud {
  private var zone: [CKRecord.ID: (seq: Int, record: CKRecord)] = [:]
  private var seq = 0
  /// 收下的上传（记录名），按先后。
  private(set) var saved: [String] = []
  private static let log = Logger(subsystem: AppIdentity.id, category: "sync")

  init(_ records: [CKRecord] = []) {
    for record in records {
      seq += 1
      zone[record.recordID] = (seq, record)
    }
  }

  /// 别的设备写下一条。
  func put(_ record: CKRecord) {
    seq += 1
    zone[record.recordID] = (seq, record)
  }

  func accountStatus() -> CKAccountStatus { .available }
  func accountName() -> String { "simulated" }

  func changes(since token: Data?, keys: [String]?) -> ZoneChangeBatch {
    let after = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
    let changed = zone.values.filter { $0.seq > after }.sorted { $0.seq < $1.seq }.map(\.record)
    return ZoneChangeBatch(modifications: changed, deletions: [], token: Data(String(seq).utf8), moreComing: false)
  }

  func records(_ ids: [CKRecord.ID]) -> [CKRecord] { ids.compactMap { zone[$0]?.record } }

  func upload(saving: [CKRecord], deleting: [CKRecord.ID]) -> SentRecords {
    for record in saving {
      put(record)
      saved.append(record.recordID.recordName)
    }
    for id in deleting { zone[id] = nil }
    Self.log.notice("替身 iCloud 收下 \(saving.count, privacy: .public) 条、删除 \(deleting.count, privacy: .public) 条")
    return SentRecords(saved: saving, deleted: deleting)
  }

  func saveZone() {}
  func subscriptions() -> [CKSubscription.ID: CKSubscription] { [:] }
  func save(_ subscription: CKSubscription) {}
  func delete(_ id: CKSubscription.ID) {}
}

extension CloudSync {
  /// 连内存里的 iCloud 替身跑真实的同步代码（调试画面）：替身的同步区里已有最低对端版本 `peerFloor`。
  public static func simulated(store: CueStore, peerFloor: Int) -> CloudSync {
    let floor = CKRecord(recordType: PeerFloor.recordType, recordID: PeerFloor(zoneID: zoneID).id)
    floor[PeerFloor.field] = peerFloor as NSNumber
    let cloud = SimulatedCloud([floor])
    return CloudSync(store: store) { cloud }
  }
}
