import CloudKit
import CueStore
import Foundation
import os

/// 收下的记录带着第一次收下的时刻（`creationDate`，按 `now` 的钟），上传的回执与之后的拉取都是这一份：投送请求的派发期限从它算。
actor SimulatedCloud: SyncCloud {
  private var zone: [CKRecord.ID: (seq: Int, record: CKRecord)] = [:]
  private var tombstones: [CKRecord.ID: (seq: Int, recordType: String)] = [:]
  private var seq = 0
  private var account = "simulated"
  /// nil：认账号一直没有回音。
  private var status: CKAccountStatus? = .available
  private(set) var accountChecks = 0
  private var uploadsFail = false
  private(set) var saved: [String] = []
  private static let log = Logger(subsystem: AppIdentity.id, category: "sync")
  private let now: @Sendable () -> Date

  init(_ records: [CKRecord] = [], now: @escaping @Sendable () -> Date = Date.init) {
    self.now = now
    for record in records {
      seq += 1
      zone[record.recordID] = (seq, record)
    }
  }

  func put(_ record: CKRecord) {
    seq += 1
    zone[record.recordID] = (seq, record)
    tombstones[record.recordID] = nil
  }

  func signIn(_ account: String) {
    self.account = account
    zone = [:]
    tombstones = [:]
  }

  func setAccount(_ status: CKAccountStatus?) { self.status = status }

  func setUploadsFail(_ fail: Bool) { uploadsFail = fail }

  func accountStatus() async -> CKAccountStatus {
    accountChecks += 1
    guard let status else {
      try? await Task.sleep(for: .seconds(3600))  // 被取消时认账号的一方已当场抛出（`withDeadline`），这里的结果不用
      return .couldNotDetermine
    }
    return status
  }
  func accountName() -> String { account }
  func relaySecret() -> Data { Data(repeating: 7, count: RelaySecret.length) }

  func changes(since token: Data?, keys: [String]) -> ZoneChangeBatch {
    let after = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
    let changed = zone.values.filter { $0.seq > after }.sorted { $0.seq < $1.seq }.map { $0.record.withoutFile }
    let gone = tombstones.filter { $0.value.seq > after }.sorted { $0.value.seq < $1.value.seq }.map { ($0.key, $0.value.recordType) }
    return ZoneChangeBatch(modifications: changed, deletions: gone, token: Data(String(seq).utf8), moreComing: false)
  }

  func records(_ ids: [CKRecord.ID]) -> [CKRecord] { ids.compactMap { zone[$0]?.record.withoutFile } }

  func uploadFile(_ record: CKRecord, progress: @Sendable (Double) -> Void) -> SentRecords {
    progress(1)
    return upload(saving: [record], deleting: [])
  }

  func resumedFileUploads() -> [ResumedUpload] { [] }

  func downloadFile(_ id: CKRecord.ID, progress: @Sendable (Double) -> Void) -> CKRecord? {
    progress(1)
    return zone[id]?.record
  }

  func upload(saving: [CKRecord], deleting: [CKRecord.ID]) -> SentRecords {
    guard !uploadsFail else {
      let offline = CKError(.networkFailure, userInfo: [NSUnderlyingErrorKey: URLError(.notConnectedToInternet)])
      return SentRecords(failedSaves: saving.map { ($0, offline) }, failedDeletes: deleting.map { ($0, offline) })
    }
    let saving = saving.map { $0.created(at: zone[$0.recordID]?.record.creationDate ?? now()) }
    for record in saving {
      put(record)
      saved.append(record.recordID.recordName)
    }
    for id in deleting {
      guard let gone = zone.removeValue(forKey: id) else { continue }
      seq += 1
      tombstones[id] = (seq, gone.record.recordType)
    }
    Self.log.notice("替身 iCloud 收下 \(saving.count, privacy: .public) 条、删除 \(deleting.count, privacy: .public) 条")
    return SentRecords(saved: saving, deleted: deleting)
  }

  func saveZone() {}
  func subscriptions() -> [CKSubscription.ID: CKSubscription] { [:] }
  func save(_ subscription: CKSubscription) {}
  func delete(_ id: CKSubscription.ID) {}
}

extension CloudSync {
  public static func simulated(store: CueStore, peerFloor: Int) -> CloudSync {
    let floor = CKRecord(recordType: PeerFloor.recordType, recordID: PeerFloor(zoneID: zoneID).id)
    floor[PeerFloor.field] = peerFloor as NSNumber
    let cloud = SimulatedCloud([floor])
    return CloudSync(store: store) { cloud }
  }
}

struct UnreachableCloud: SyncCloud {
  private static let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
  static var failure: CKError { CKError(.networkUnavailable, userInfo: [NSUnderlyingErrorKey: offline]) }

  func accountStatus() -> CKAccountStatus { .available }
  func accountName() -> String { "simulated" }
  func relaySecret() throws -> Data { throw Self.failure }
  func changes(since token: Data?, keys: [String]) throws -> ZoneChangeBatch { throw Self.failure }
  func records(_ ids: [CKRecord.ID]) throws -> [CKRecord] { throw Self.failure }
  func upload(saving: [CKRecord], deleting: [CKRecord.ID]) throws -> SentRecords {
    let ids = saving.map(\.recordID) + deleting
    throw CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: Dictionary(uniqueKeysWithValues: ids.map { ($0, Self.offline) })])
  }
  func uploadFile(_ record: CKRecord, progress: @Sendable (Double) -> Void) throws -> SentRecords { throw Self.failure }
  func resumedFileUploads() throws -> [ResumedUpload] { throw Self.failure }
  func downloadFile(_ id: CKRecord.ID, progress: @Sendable (Double) -> Void) throws -> CKRecord? { throw Self.failure }
  func saveZone() throws { throw Self.failure }
  func subscriptions() throws -> [CKSubscription.ID: CKSubscription] { throw Self.failure }
  func save(_ subscription: CKSubscription) throws { throw Self.failure }
  func delete(_ id: CKSubscription.ID) throws { throw Self.failure }
}

extension CloudSync {
  public static func unreachable(store: CueStore) -> CloudSync { CloudSync(store: store) { UnreachableCloud() } }
}

extension CKRecord {
  /// 带着服务器收下时刻的一份：`creationDate` 没有公开的写法，整条归档后读回时换掉那一项。
  fileprivate func created(at date: Date) -> CKRecord {
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    encode(with: archiver)
    archiver.finishEncoding()
    guard let reader = try? CreationStamp(forReadingFrom: archiver.encodedData, date: date), let stamped = CKRecord(coder: reader) else { return self }
    return stamped
  }

  var withoutFile: CKRecord {
    guard self[RecordMapper.fileKey] != nil, let copy = copy() as? CKRecord else { return self }
    copy[RecordMapper.fileKey] = nil
    return copy
  }
}

private final class CreationStamp: NSKeyedUnarchiver {
  private let date: Date

  init(forReadingFrom data: Data, date: Date) throws {
    self.date = date
    try super.init(forReadingFrom: data)
    requiresSecureCoding = true
  }

  override func decodeObject(forKey key: String) -> Any? {
    key == "RecordCtime" ? date : super.decodeObject(forKey: key)
  }
}
