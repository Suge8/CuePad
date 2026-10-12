import CloudKit
import Foundation

/// 一次直接上传的结果，与引擎的发送结果同形，交给协调器同一个入口（`.sent`）。
struct SentRecords: Sendable {
  var saved: [CKRecord] = []
  var failedSaves: [(record: CKRecord, error: CKError)] = []
  var deleted: [CKRecord.ID] = []
  var failedDeletes: [(id: CKRecord.ID, error: CKError)] = []
}

/// 立即上传一条记录的结局。
enum SendNowResult: Equatable {
  /// 服务器收下了，本机没有更新的版本待传。
  case received
  /// 服务器收下了，但上传期间本机又改过：更新的版本仍待推送（已登记给引擎）。
  case receivedWithNewerVersionPending
  /// 服务器没收下，仍待推送。
  case rejected
}

/// 能把记录直接存进（或从中删除）同步区的数据库（真实实现见 `DatabaseRecordUploader`）。
protocol RecordUploader: Sendable {
  func upload(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> SentRecords
}

/// 立即上传的通路，与 `ZoneChangePuller` 对称：不经 CKSyncEngine。引擎一次只做一件事，
/// 排在它前面的拉取（含大附件下载）、上传与退避都会拖住显式的 `sendChanges`，而手机发出的请求每晚一秒用户就多等一秒。
struct DatabaseRecordUploader: RecordUploader {
  let database: CKDatabase

  func upload(saving records: [CKRecord], deleting ids: [CKRecord.ID]) async throws -> SentRecords {
    let configuration = CKOperation.Configuration()
    configuration.qualityOfService = .userInitiated
    let results = try await database.configuredWith(configuration: configuration) {
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
}

extension Error {
  fileprivate var asCloudKitError: CKError { self as? CKError ?? CKError(.internalError) }
}
