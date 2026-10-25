import CloudKit
import CueStore
import Foundation
import os

/// 内存里的 iCloud 替身：账号总是可用，同步区是一组按写入先后编号的记录，令牌就是编号；收下的上传照单记下（`saved`）。
/// 测试与调试画面用它跑真实的同步代码（`CloudSync`），只换掉网络那一头。
actor SimulatedCloud: SyncCloud {
  private var zone: [CKRecord.ID: (seq: Int, record: CKRecord)] = [:]
  private var seq = 0
  private var account = "simulated"
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

  /// 换登了另一个 iCloud 账号：它的同步区是空的。
  func signIn(_ account: String) {
    self.account = account
    zone = [:]
  }

  func accountStatus() -> CKAccountStatus { .available }
  func accountName() -> String { account }
  func relaySecret() -> Data { Data(repeating: 7, count: RelaySecret.length) }

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

/// 断了网的 iCloud 替身：认得出账号，其余请求都像断网那样失败——拉取与订阅是 CloudKit 包着的 -1009，上传是包在 `partialFailure` 里的逐条 -1009。
/// 调试画面用它看断网时各处界面怎么说（`CloudSync.unreachable`）。
struct UnreachableCloud: SyncCloud {
  private static let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
  static var failure: CKError { CKError(.networkUnavailable, userInfo: [NSUnderlyingErrorKey: offline]) }

  func accountStatus() -> CKAccountStatus { .available }
  func accountName() -> String { "simulated" }
  func relaySecret() throws -> Data { throw Self.failure }
  func changes(since token: Data?, keys: [String]?) throws -> ZoneChangeBatch { throw Self.failure }
  func records(_ ids: [CKRecord.ID]) throws -> [CKRecord] { throw Self.failure }
  func upload(saving: [CKRecord], deleting: [CKRecord.ID]) throws -> SentRecords {
    let ids = saving.map(\.recordID) + deleting
    throw CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: Dictionary(uniqueKeysWithValues: ids.map { ($0, Self.offline) })])
  }
  func saveZone() throws { throw Self.failure }
  func subscriptions() throws -> [CKSubscription.ID: CKSubscription] { throw Self.failure }
  func save(_ subscription: CKSubscription) throws { throw Self.failure }
  func delete(_ id: CKSubscription.ID) throws { throw Self.failure }
}

extension CloudSync {
  /// 连断了网的 iCloud 替身（`UnreachableCloud`，调试画面）。
  public static func unreachable(store: CueStore) -> CloudSync { CloudSync(store: store) { UnreachableCloud() } }
}
