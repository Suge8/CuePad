import CloudKit
import Foundation
import Synchronization

/// 文件那一路在 CloudKit 上：上传是长期操作（`isLongLived`），App 退出后由系统（cloudd）传完，下次启动按操作 ID 接上；取只要文件字段。
/// 开发环境实测（research/asset-probe，2026-10-27）：100MB 传到四成时杀掉进程，cloudd 照样传完，下一个进程接上当场拿到收下的结果；
/// 进度回调约 0.26 秒一次。空闲超时照 `CloudDatabase.database`：一直有数据在走的大文件不会被它断开。
extension CloudDatabase {
  func uploadFile(_ record: CKRecord, progress: @escaping @Sendable (Double) -> Void) async throws -> SentRecords {
    let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
    operation.savePolicy = .ifServerRecordUnchanged
    operation.isAtomic = false
    let configuration = Self.fileConfiguration
    configuration.isLongLived = true
    operation.configuration = configuration
    return try await run(operation, progress: progress)
  }

  func resumedFileUploads() async throws -> [ResumedUpload] {
    var found: [ResumedUpload] = []
    for id in try await container.allLongLivedOperationIDs() {
      // 这个进程自己加的还在跑（停下又开始同步）：结果照常回到加它的那一处，不再加一次
      guard !Self.ownOperations.withLock({ $0.contains(id) }),
        let operation = try await container.longLivedOperation(for: id) as? CKModifyRecordsOperation,
        let records = operation.recordsToSave, records.allSatisfy({ $0.recordID.zoneID == zoneID })
      else { continue }
      found.append(ResumedUpload(records: records) { progress in try await run(operation, progress: progress) })
    }
    return found
  }

  func downloadFile(_ id: CKRecord.ID, progress: @escaping @Sendable (Double) -> Void) async throws -> CKRecord? {
    let operation = CKFetchRecordsOperation(recordIDs: [id])
    operation.desiredKeys = [RecordMapper.fileKey]
    operation.configuration = Self.fileConfiguration
    operation.perRecordProgressBlock = { _, fraction in progress(fraction) }
    let found = Mutex<Result<CKRecord?, any Error>>(.success(nil))
    operation.perRecordResultBlock = { _, result in
      found.withLock {
        $0 = switch result {
        case .success(let record): .success(record)
        case .failure(let error as CKError) where error.code == .unknownItem: .success(nil)  // 这期间被删了
        case .failure(let error): .failure(error)
        }
      }
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (done: CheckedContinuation<CKRecord?, any Error>) in
        operation.fetchRecordsResultBlock = { result in
          if case .failure(let error) = result, (error as? CKError)?.code != .partialFailure { return done.resume(throwing: error) }
          done.resume(with: found.withLock { $0 })
        }
        container.privateCloudDatabase.add(operation)
      }
    } onCancel: {
      operation.cancel()
    }
  }

  /// 文件操作的配置：空闲超时同别的请求；服务质量写明 userInitiated。不写时 CloudKit 当成可延后的（日志里 `discretionary=Infers Disc`、
  /// qos=Default），2026-10-27 开发环境实测 100MB 的上传与几个小文件的取两分钟进度都停在 0，写明之后照常传。
  private static var fileConfiguration: CKOperation.Configuration {
    let configuration = CKOperation.Configuration()
    configuration.timeoutIntervalForRequest = RequestLimits.request.seconds
    configuration.qualityOfService = .userInitiated
    return configuration
  }

  /// 这个进程加进库的上传操作。
  private static let ownOperations = Mutex<Set<CKOperation.ID>>([])

  /// 加进库、等结果：逐条的结果收成 `SentRecords`（同 `upload`），整个操作的失败抛出。不随任务取消：
  /// 退出时停下同步也要让系统接着传完（`stop` 不等它）。
  private func run(_ operation: CKModifyRecordsOperation, progress: @escaping @Sendable (Double) -> Void) async throws -> SentRecords {
    let byID = Dictionary((operation.recordsToSave ?? []).map { ($0.recordID, $0) }, uniquingKeysWith: { $1 })
    let sent = Mutex(SentRecords())
    operation.perRecordProgressBlock = { _, fraction in progress(fraction) }
    operation.perRecordSaveBlock = { id, result in
      sent.withLock { sent in
        switch result {
        case .success(let record): sent.saved.append(record)
        case .failure(let error): if let record = byID[id] { sent.failedSaves.append((record, error.asCloudKitError)) }
        }
      }
    }
    Self.ownOperations.withLock { _ = $0.insert(operation.operationID) }
    defer { Self.ownOperations.withLock { _ = $0.remove(operation.operationID) } }
    return try await withCheckedThrowingContinuation { (done: CheckedContinuation<SentRecords, any Error>) in
      operation.modifyRecordsResultBlock = { result in
        if case .failure(let error) = result, (error as? CKError)?.code != .partialFailure { return done.resume(throwing: error) }
        done.resume(returning: sent.withLock { $0 })
      }
      container.privateCloudDatabase.add(operation)
    }
  }
}
