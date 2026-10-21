import CloudKit
import Foundation

/// 同步区里自某个令牌以来的一批变化。令牌是 `CKServerChangeToken` 的归档，测试可换成任意字节。
struct ZoneChangeBatch: Sendable {
  var modifications: [CKRecord]
  var deletions: [(id: CKRecord.ID, recordType: String)]
  var token: Data
  var moreComing: Bool
}

/// 拉：同步区的变化与按 ID 取整条记录（真实实现见 `CloudDatabase`）。`keys` 是要带回的字段（nil：整条记录）。
protocol ZoneChangeSource: Sendable {
  func changes(since token: Data?, keys: [String]?) async throws -> ZoneChangeBatch
  /// 按 ID 取整条记录（取不到的略过）。一次不超过 `CloudKitLimits.recordsPerRequest` 条，由调用方分批。
  func records(_ ids: [CKRecord.ID]) async throws -> [CKRecord]
}

/// 推：存进（或从中删除）同步区，以及建同步区（真实实现见 `CloudDatabase`）。
protocol RecordUploader: Sendable {
  func upload(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> SentRecords
  func saveZone() async throws
}

/// 一次上传的结果，交给协调器的 `.sent` 入口。
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

struct CloudDatabase: ZoneChangeSource, RecordUploader {
  let database: CKDatabase
  let zoneID: CKRecordZone.ID

  func changes(since token: Data?, keys: [String]?) async throws -> ZoneChangeBatch {
    let since = try token.flatMap { try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
    let result = try await database.recordZoneChanges(inZoneWith: zoneID, since: since, desiredKeys: keys)
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
    for (_, outcome) in try await database.records(for: ids) {
      switch outcome {
      case .success(let record): found.append(record)
      case .failure(let error as CKError) where error.code == .unknownItem: continue  // 这期间被删了
      case .failure(let error): throw error
      }
    }
    return found
  }

  func upload(saving records: [CKRecord], deleting ids: [CKRecord.ID]) async throws -> SentRecords {
    let results = try await database.modifyRecords(saving: records, deleting: ids, savePolicy: .ifServerRecordUnchanged, atomically: false)
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
    _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
  }
}

extension Error {
  fileprivate var asCloudKitError: CKError { self as? CKError ?? CKError(.internalError) }
}
