import CloudKit
import Foundation

/// 同步表行 ↔ CKRecord。recordType = 表名，recordName = 行 id；列名即字段名。
/// 用户内容（正文、变量取值、名称、发送内容）放 `encryptedValues`，结构性字段（排序键、时间、引用、标志）保持明文。
enum RecordMapper {
  static let encryptedColumns: [Table: Set<String>] = [
    .projects: ["name"],
    .cards: ["body", "variableValues"],
    .sendRecords: ["content", "targetName", "targetRef"],
    .piSessionStates: ["title", "detail", "folder", "lastPrompt", "lastReply", "question", "launchToken", "subagents", "pendingPrompt", "model", "thinking", "models", "context", "commands"],
    .deliveryRequests: ["content", "targetName", "targetRef", "resultDetail"],
    .directoryBindings: ["hostName", "folder"],
    .piMessages: ["text"],
    .previews: ["name", "title"],
  ]

  /// 服务端要查询的字段（订阅谓词等），schema 里建可查询索引。加密字段服务端看不见，不能出现在这里。
  static let queryableColumns: [Table: Set<String>] = [
    .piSessionStates: [PiAlertSubscriptions.flagField]
  ]

  static func recordType(for table: Table) -> String { table.rawValue }

  static func table(named recordType: String) -> Table? {
    Table(rawValue: recordType).flatMap { Table.synced.contains($0) ? $0 : nil }
  }

  /// `base` 是上次从服务器拿到的记录（带系统字段），在它上面改字段才能通过服务器的版本校验；没有则新建。
  static func record(from row: SyncRow, zoneID: CKRecordZone.ID, base: CKRecord? = nil) -> CKRecord {
    let record = base ?? CKRecord(
      recordType: row.table.rawValue, recordID: CKRecord.ID(recordName: row.id, zoneID: zoneID))
    let encrypted = encryptedColumns[row.table] ?? []
    for column in row.table.columns where column != "id" {
      let value = row.fields[column] ?? .null
      if encrypted.contains(column) {
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
    let encrypted = encryptedColumns[table] ?? []
    var fields: [String: SQLValue] = ["id": .text(record.recordID.recordName)]
    for column in table.columns where column != "id" {
      let raw: Any? = encrypted.contains(column) ? record.encryptedValues[column] : record[column]
      switch raw {
      case let text as String: fields[column] = .text(text)
      case let number as NSNumber: fields[column] = .int(number.int64Value)
      default: fields[column] = .null
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
