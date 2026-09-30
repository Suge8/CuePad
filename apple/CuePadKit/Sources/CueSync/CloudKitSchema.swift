import Foundation

/// CloudKit 数据结构（cktool 的 .ckdb 文本），由记录映射推出，不手写第二份：
/// 每个同步表一个记录类型；字段名与类型取自表的真实列（TEXT→STRING，INTEGER→INT64）；
/// `RecordMapper.encryptedColumns` 里的字段声明为加密；`RecordMapper.queryableColumns` 里的字段与每个类型的
/// recordName 建可查询索引；附件记录另有资产字段 `file`。权限只给私有库所需的创建者与 iCloud 用户。
/// 提交的文件是 `apple/CloudKit/cuepad.ckdb`，测试保证它与这里的输出一致。
///
/// 生产环境的结构只能增不能删，开发环境导入的结构也不能删掉生产里已有的字段与类型：已下线的（`retired`）照原样声明，
/// 客户端不再读写它们。
enum CloudKitSchema {
  /// 生产环境里部署过、已不再使用的字段（按记录类型）与记录类型。
  static let retiredFields: [String: [(name: String, declaration: String)]] = ["cards": [("isFavorite", "INT64")]]
  static let retiredTypes: [(name: String, fields: [(name: String, declaration: String)])] = [
    ("tags", [("color", "STRING"), ("createdAt", "INT64"), ("modifiedAt", "INT64"), ("name", "ENCRYPTED STRING")]),
    ("cardTags", [("cardID", "STRING"), ("createdAt", "INT64"), ("modifiedAt", "INT64"), ("tagID", "STRING")]),
    (
      "probes",
      [
        ("kind", "STRING"), ("modifiedAt", "INT64"), ("origin", "STRING"), ("peerAppliedAt", "INT64"),
        ("peerFetchStartedAt", "INT64"), ("run", "STRING"), ("sentAt", "INT64"), ("seq", "INT64"),
      ]
    ),
  ]

  static func generate() async throws -> String {
    let directory = FileManager.default.temporaryDirectory.appending(path: "cuepad-schema-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CueStore(url: directory.appending(path: "cuepad.db"))

    var types: [String] = []
    for table in Table.synced {
      let sqlTypes = try await store.columnTypes(of: table)
      var fields: [(name: String, declaration: String)] = [("\"___recordID\"", "REFERENCE QUERYABLE")]
      for column in table.columns where column != "id" {
        let encrypted = RecordMapper.encryptedColumns[table]?.contains(column) == true
        let queryable = RecordMapper.queryableColumns[table]?.contains(column) == true
        let type = sqlTypes[column] == "INTEGER" ? "INT64" : "STRING"
        fields.append((column, [encrypted ? "ENCRYPTED" : nil, type, queryable ? "QUERYABLE" : nil].compactMap { $0 }.joined(separator: " ")))
      }
      if table == .attachments { fields.append(("file", "ASSET")) }
      fields += retiredFields[table.rawValue] ?? []
      types.append(recordType(table.rawValue, fields))
    }
    for retired in retiredTypes {
      types.append(recordType(retired.name, [("\"___recordID\"", "REFERENCE QUERYABLE")] + retired.fields))
    }
    return "DEFINE SCHEMA\n\n" + types.joined(separator: "\n\n") + "\n"
  }

  private static func recordType(_ name: String, _ fields: [(name: String, declaration: String)]) -> String {
    let width = fields.map(\.name.count).max() ?? 0
    var lines = fields.map { "        \($0.name.padding(toLength: width, withPad: " ", startingAt: 0)) \($0.declaration)," }
    lines.append(#"        GRANT WRITE TO "_creator","#)
    lines.append(#"        GRANT CREATE TO "_icloud""#)
    return "    RECORD TYPE \(name) (\n" + lines.joined(separator: "\n") + "\n    );"
  }
}
