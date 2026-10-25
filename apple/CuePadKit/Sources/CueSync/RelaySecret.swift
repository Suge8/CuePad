import CloudKit
import CryptoKit
import Foundation

/// 门铃的密钥（App 的 `Relay` 由它派生房间号与签名）：只在你自己的 iCloud 里——私有库单独一个区里的一条记录，值在加密字段里，Apple 与中转都读不到。
/// 不放进同步区：已发出的版本拉到会当未知类型报给你。第一台要用门铃的设备生成 32 字节随机数存进去；两台同时生成时以先存进去的为准
/// （不覆盖已有的那条，被拒就用服务器上的）。经同步层取（`CloudSync.relaySecret`）：同一个容器、同样的请求时限与错误归类。
///
/// 没选 iCloud 钥匙串：它另有开关，关着的设备拿不到；同步时机不定、同时生成的两台没有先来后到可认，会各进各的房间；
/// Mac 还要另加钥匙串权限。放在 CloudKit 里，能同步的设备就拿得到同一把，换账号自然换钥匙。
enum RelaySecret {
  static let zoneName = "Relay"
  static let recordType = "relaySecrets"
  static let field = "secret"
  static let recordID = CKRecord.ID(recordName: "relaySecret", zoneID: CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName))
  static let length = 32

  struct Malformed: Error {}

  static func generated() -> CKRecord {
    let record = CKRecord(recordType: recordType, recordID: recordID)
    record.encryptedValues[field] = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    return record
  }

  static func value(of record: CKRecord) throws -> Data {
    guard let secret = record.encryptedValues[field] as? Data, secret.count == length else { throw Malformed() }
    return secret
  }
}

extension CloudDatabase {
  func relaySecret() async throws -> Data {
    do {
      return try RelaySecret.value(of: try await database { try await $0.record(for: RelaySecret.recordID) })
    } catch let error as CKError where error.code == .unknownItem {
      return try await createRelaySecret()
    } catch let error as CKError where error.code == .zoneNotFound {
      _ = try await database { try await $0.save(CKRecordZone(zoneID: RelaySecret.recordID.zoneID)) }
      return try await createRelaySecret()
    }
  }

  private func createRelaySecret() async throws -> Data {
    let record = RelaySecret.generated()
    let (saved, _) = try await database { try await $0.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged) }
    switch saved[record.recordID] {
    case .success(let record): return try RelaySecret.value(of: record)
    case .failure(let error as CKError) where error.code == .serverRecordChanged:
      guard let server = error.serverRecord else { throw error }
      return try RelaySecret.value(of: server)
    case .failure(let error): throw error
    case nil: throw RelaySecret.Malformed()
    }
  }
}
