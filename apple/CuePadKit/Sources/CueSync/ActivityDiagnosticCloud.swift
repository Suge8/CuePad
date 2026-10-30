import CloudKit
import CueStore
import Foundation

/// 独立私有区的一台设备一份取证；不进业务同步区，旧版不会把诊断认成未知业务记录。
/// 写入绑定资料所属账号；只读导出不创建区、记录、订阅或资料库。
public struct ActivityDiagnosticCloud: Sendable {
  static let zoneName = "ActivityDiagnostics"
  static let recordType = "activityDiagnostics"
  static let field = "report"
  private let container: CKContainer

  public init() {
    container = CKContainer(identifier: AppIdentity.iCloudContainer)
  }

  /// 在事件发生处同步截取资料的所属账号；不能等异步上传时再读当前账号。
  @MainActor public static func account(in store: CueStore) throws -> Data? {
    try store.snapshot { try $0.syncState(SyncCoordinator.accountKey) }.value
  }

  public func save(_ report: ActivityDiagnosticReport, account: String) async throws {
    let user = try await container.userRecordID()
    guard user.recordName == account else { throw CancellationError() }
    let zone = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: account)
    let record = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: report.device, zoneID: zone))
    record.encryptedValues[Self.field] = try JSONEncoder().encode(report)
    let cloud = CloudDatabase(container: container, zoneID: zone)
    do {
      try await save(record, in: cloud)
    } catch let error as CKError where error.code == .zoneNotFound {
      _ = try await cloud.database { try await $0.save(CKRecordZone(zoneID: zone)) }
      try Task.checkCancellation()
      try await save(record, in: cloud)
    }
  }

  private func save(_ record: CKRecord, in cloud: CloudDatabase) async throws {
    let result = try await cloud.database { try await $0.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys) }
    guard let saved = result.saveResults[record.recordID] else { throw CKError(.internalError) }
    _ = try saved.get()
  }

  public func reports() async throws -> [ActivityDiagnosticReport] {
    let user = try await container.userRecordID()
    let zone = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: user.recordName)
    let cloud = CloudDatabase(container: container, zoneID: zone)
    var token: CKServerChangeToken?
    var reports: [CKRecord.ID: ActivityDiagnosticReport] = [:]
    do {
      while true {
        let since = token
        let batch = try await cloud.database {
          try await $0.recordZoneChanges(inZoneWith: zone, since: since, desiredKeys: [Self.field])
        }
        for (_, outcome) in batch.modificationResultsByID {
          let record = try outcome.get().record
          guard record.recordType == Self.recordType else { continue }
          guard let data = record.encryptedValues[Self.field] as? Data else { throw CocoaError(.coderReadCorrupt) }
          reports[record.recordID] = try JSONDecoder().decode(ActivityDiagnosticReport.self, from: data)
        }
        for deletion in batch.deletions { reports.removeValue(forKey: deletion.recordID) }
        guard batch.moreComing else { return reports.values.sorted { $0.device < $1.device } }
        token = batch.changeToken
      }
    } catch let error as CKError where error.code == .zoneNotFound {
      return []
    }
  }
}
