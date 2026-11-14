import CloudKit
import Foundation

/// 加密字段（`Field.Storage.encrypted`）放 `encryptedValues`，其余放明文字段。
enum RecordMapper {
  /// 附件记录的资产字段：文件本身，不是列（`CloudKitSchema`）。拉取不带它，文件另走一路（`FileCloud`）。
  static let fileKey = "file"

  static func table(named recordType: String) -> Table? {
    Table(rawValue: recordType).flatMap { Table.synced.contains($0) ? $0 : nil }
  }

  /// `base` 是上次从服务器拿到的记录（带系统字段），在它上面改字段才能通过服务器的版本校验；没有则新建。上传是整条。
  static func record(from row: SyncRow, zoneID: CKRecordZone.ID, base: CKRecord? = nil) -> CKRecord {
    let record = base ?? CKRecord(
      recordType: row.table.rawValue, recordID: CKRecord.ID(recordName: row.id, zoneID: zoneID))
    for field in row.table.syncedFields where field.name != "id" {
      let column = field.name, value = row.fields[column] ?? .null
      if field.storage == .encrypted {
        switch value {
        case .text(let text): record.encryptedValues[column] = text
        case .int(let number): record.encryptedValues[column] = number
        case .null, .blob: record.encryptedValues[column] = nil
        }
      } else {
        switch value {
        case .text(let text): record[column] = text as NSString
        case .int(let number): record[column] = number as NSNumber
        case .null, .blob: record[column] = nil
        }
      }
    }
    return record
  }

  /// 未知记录类型返回 nil。缺失的字段读作 NULL（其他版本没有的列）。
  static func row(from record: CKRecord) -> SyncRow? {
    guard let table = table(named: record.recordType) else { return nil }
    var fields: [String: SQLValue] = ["id": .text(record.recordID.recordName)]
    for field in table.syncedFields where field.name != "id" {
      let raw: Any? = field.storage == .encrypted ? record.encryptedValues[field.name] : record[field.name]
      switch raw {
      case let text as String: fields[field.name] = .text(text)
      case let number as NSNumber: fields[field.name] = .int(number.int64Value)
      default: fields[field.name] = .null
      }
    }
    return SyncRow(table: table, fields: fields)
  }

  static func encodeSystemFields(_ record: CKRecord) -> Data {
    let coder = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: coder)
    coder.finishEncoding()
    return coder.encodedData
  }

  static func decodeSystemFields(_ data: Data) -> CKRecord? {
    guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
    coder.requiresSecureCoding = true
    defer { coder.finishDecoding() }
    return CKRecord(coder: coder)
  }
}
