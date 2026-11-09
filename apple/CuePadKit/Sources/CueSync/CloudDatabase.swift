import CloudKit
import Foundation

/// 令牌是 `CKServerChangeToken` 的归档，测试可换成任意字节。
struct ZoneChangeBatch: Sendable {
  var modifications: [CKRecord]
  var deletions: [(id: CKRecord.ID, recordType: String)]
  var token: Data
  var moreComing: Bool
}

/// 都不带附件的文件：文件另走一路（`FileCloud`）。
protocol ZoneChangeSource: Sendable {
  func changes(since token: Data?, keys: [String]) async throws -> ZoneChangeBatch
  /// 按 ID 取整条记录、不带文件（取不到的略过）。一次不超过 `CloudKitLimits.recordsPerRequest` 条，由调用方分批。
  func records(_ ids: [CKRecord.ID]) async throws -> [CKRecord]
}

protocol RecordUploader: Sendable {
  func upload(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> SentRecords
  func saveZone() async throws
}

struct SentRecords: Sendable {
  var saved: [CKRecord] = []
  var failedSaves: [(record: CKRecord, error: CKError)] = []
  var deleted: [CKRecord.ID] = []
  var failedDeletes: [(id: CKRecord.ID, error: CKError)] = []
}

/// CloudKit 单次请求能带的记录数上限（超出报 `limitExceeded`）。
enum CloudKitLimits {
  static let recordsPerRequest = 400
}

protocol FileCloud: Sendable {
  /// 传一条带文件的附件记录。CloudKit 里是长期操作：进程退出后系统接着传，下次启动由 `resumedFileUploads` 接上。
  func uploadFile(_ record: CKRecord, progress: @escaping @Sendable (Double) -> Void) async throws -> SentRecords
  /// 上个进程交给系统、还没交回结果的文件上传（传完了的结果也在这里交回）。
  func resumedFileUploads() async throws -> [ResumedUpload]
  /// 只取这条记录的文件（`fileKey`）；记录已不在为 nil。
  func downloadFile(_ id: CKRecord.ID, progress: @escaping @Sendable (Double) -> Void) async throws -> CKRecord?
}

struct ResumedUpload: Sendable {
  var records: [CKRecord]
  var result: @Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws -> SentRecords
}

protocol SyncCloud: ZoneChangeSource, RecordUploader, SubscriptionStore, FileCloud {
  func accountStatus() async throws -> CKAccountStatus
  func accountName() async throws -> String
  /// 门铃的密钥（`RelaySecret`），没有就生成一把存进去。
  func relaySecret() async throws -> Data
}

struct CloudDatabase: SyncCloud {
  let container: CKContainer
  let zoneID: CKRecordZone.ID

  /// 数据库的每个请求都带 CloudKit 自己的超时：`RequestLimits.request` 没有新数据（空闲，不是总用时；文件那一路同样，见 `CloudDatabase+Files`）就失败，
  /// 归为连不上、退避重发。默认的 60 秒太长：挂住的一批挡着后面的话一起等。
  func database<R>(_ body: @escaping @Sendable (CKDatabase) async throws -> R) async throws -> R {
    let configuration = CKOperation.Configuration()
    configuration.timeoutIntervalForRequest = RequestLimits.request.seconds
    return try await container.privateCloudDatabase.configuredWith(configuration: configuration) { try await body($0) }
  }

  func accountStatus() async throws -> CKAccountStatus { try await container.accountStatus() }
  func accountName() async throws -> String { try await container.userRecordID().recordName }

  func subscriptions() async throws -> [CKSubscription.ID: CKSubscription] {
    Dictionary(uniqueKeysWithValues: try await database { try await $0.allSubscriptions() }.map { ($0.subscriptionID, $0) })
  }

  func save(_ subscription: CKSubscription) async throws { _ = try await database { try await $0.save(subscription) } }
  func delete(_ id: CKSubscription.ID) async throws { _ = try await database { try await $0.deleteSubscription(withID: id) } }

  func changes(since token: Data?, keys: [String]) async throws -> ZoneChangeBatch {
    let since = try token.flatMap { try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
    let result = try await database { try await $0.recordZoneChanges(inZoneWith: zoneID, since: since, desiredKeys: keys) }
    var modifications: [CKRecord] = []
    for (_, outcome) in result.modificationResultsByID {
      // 单条取不出来的整批重来：跳过它，令牌就跨过了这条记录
      modifications.append(try outcome.get().record)
    }
    return ZoneChangeBatch(
      modifications: modifications, deletions: result.deletions.map { ($0.recordID, $0.recordType) },
      token: try NSKeyedArchiver.archivedData(withRootObject: result.changeToken, requiringSecureCoding: true),
      moreComing: result.moreComing)
  }

  func records(_ ids: [CKRecord.ID]) async throws -> [CKRecord] {
    var found: [CKRecord] = []
    for (_, outcome) in try await database({ try await $0.records(for: ids, desiredKeys: ZonePuller.fieldsWithoutFiles) }) {
      switch outcome {
      case .success(let record): found.append(record)
      case .failure(let error as CKError) where error.code == .unknownItem: continue  // 这期间被删了
      case .failure(let error): throw error
      }
    }
    return found
  }

  func upload(saving records: [CKRecord], deleting ids: [CKRecord.ID]) async throws -> SentRecords {
    let results = try await database {
      try await $0.modifyRecords(saving: records, deleting: ids, savePolicy: .ifServerRecordUnchanged, atomically: false)
    }
    var sent = SentRecords()
    for record in records {
      switch results.saveResults[record.recordID] {
      case .success(let saved): sent.saved.append(saved)
      case .failure(let error): sent.failedSaves.append((record, error.asCloudKitError))
      case nil: break
      }
    }
    for id in ids {
      switch results.deleteResults[id] {
      case .success: sent.deleted.append(id)
      case .failure(let error): sent.failedDeletes.append((id, error.asCloudKitError))
      case nil: break
      }
    }
    return sent
  }

  func saveZone() async throws {
    _ = try await database { try await $0.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: []) }
  }
}

extension Error {
  /// 单条结果里不是 CKError 的（断网时见过 URL 错误）保留成底层错误，归类（`SyncFault`）照样认得出来。
  var asCloudKitError: CKError { self as? CKError ?? CKError(.internalError, userInfo: [NSUnderlyingErrorKey: self]) }
}
