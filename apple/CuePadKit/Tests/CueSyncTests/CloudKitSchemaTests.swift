import CueStore
import Foundation
import Testing

@testable import CueSync

/// CloudKit 数据结构（.ckdb）是记录映射的派生物：生成器读同步表的真实列类型、`RecordMapper` 的加密与可查询声明。
/// 仓库里提交的 `apple/CloudKit/cuepad.ckdb` 必须与生成结果一致；映射变了这里会失败，按提示重新生成并导入。
@Suite struct CloudKitSchemaTests {
  static let regenerating = ProcessInfo.processInfo.environment["CUEPAD_REGENERATE_SCHEMA"] == "1"

  /// apple/CuePadKit/Tests/CueSyncTests/<this file> → apple/CloudKit/cuepad.ckdb
  static var schemaFile: URL {
    URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "CloudKit/cuepad.ckdb")
  }

  /// 去掉对齐用的多余空格，断言只关心词序。
  private func lines(_ schema: String) -> [String] {
    schema.split(separator: "\n").map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
  }

  private func fields(of type: String, in schema: String) -> [String] {
    var inside = false
    var result: [String] = []
    for line in lines(schema) {
      if line == "RECORD TYPE \(type) (" { inside = true; continue }
      if inside, line == ");" { break }
      if inside { result.append(line.hasSuffix(",") ? String(line.dropLast()) : line) }
    }
    return result
  }

  @Test func committedSchemaFileMatchesTheRecordMapping() async throws {
    let generated = try await CloudKitSchema.generate()
    let committed = try String(contentsOf: Self.schemaFile, encoding: .utf8)
    #expect(generated == committed, "记录映射变了：运行 CUEPAD_REGENERATE_SCHEMA=1 swift test --filter regenerateSchemaFile 重新生成，再用 cktool import-schema 导入（见 apple/README.md「同步」）")
  }

  @Test(.enabled(if: CloudKitSchemaTests.regenerating))
  func regenerateSchemaFile() async throws {
    try await CloudKitSchema.generate().write(to: Self.schemaFile, atomically: true, encoding: .utf8)
  }

  @Test func everySyncedTableIsARecordTypeAndNothingElseIs() async throws {
    let schema = try await CloudKitSchema.generate()
    let types = lines(schema).filter { $0.hasPrefix("RECORD TYPE ") }.map { $0.dropFirst("RECORD TYPE ".count).dropLast(2) }
    #expect(types.map(String.init) == Table.synced.map(\.rawValue))  // 本机表（piSessions 等）不进 CloudKit
  }

  @Test func fieldTypesAndEncryptionFollowTheMapping() async throws {
    let schema = try await CloudKitSchema.generate()
    let cards = fields(of: "cards", in: schema)
    #expect(cards.contains("body ENCRYPTED STRING") && cards.contains("variableValues ENCRYPTED STRING"))
    #expect(cards.contains("sortKey STRING") && cards.contains("modifiedAt INT64") && cards.contains("isFavorite INT64"))
    #expect(!cards.contains { $0.hasPrefix("id ") })  // 行 id 是 recordName，不是字段

    for (table, encrypted) in RecordMapper.encryptedColumns {
      let declared = fields(of: table.rawValue, in: schema)
      for column in encrypted { #expect(declared.contains { $0.hasPrefix("\(column) ENCRYPTED ") }, "\(table.rawValue).\(column) 应为加密字段") }
    }
    let plain = fields(of: "piSessionStates", in: schema).filter { $0.hasPrefix("sessionID ") || $0.hasPrefix("state ") || $0.hasPrefix("hostID ") }
    #expect(plain.allSatisfy { !$0.contains("ENCRYPTED") })  // 服务端要能看见的结构性字段保持明文
    #expect(fields(of: "attachments", in: schema).contains("file ASSET"))
  }

  @Test func fieldsTheServerQueriesAreIndexed() async throws {
    let schema = try await CloudKitSchema.generate()
    #expect(fields(of: "piSessionStates", in: schema).contains("notify STRING QUERYABLE"))  // 订阅谓词用它
    for table in Table.synced {
      #expect(fields(of: table.rawValue, in: schema).contains("\"___recordID\" REFERENCE QUERYABLE"), "\(table.rawValue) 的 recordName 需要可查询")
    }
    #expect(RecordMapper.queryableColumns[.piSessionStates]?.contains(PiAlertSubscriptions.flagField) == true)
  }

  @Test func onlyThePrivateDatabaseGrantsAreDeclared() async throws {
    let schema = try await CloudKitSchema.generate()
    #expect(!schema.contains("_world"))
    for table in Table.synced {
      let declared = fields(of: table.rawValue, in: schema).filter { $0.hasPrefix("GRANT") }
      #expect(declared == [#"GRANT WRITE TO "_creator""#, #"GRANT CREATE TO "_icloud""#])
    }
  }

  @Test func encryptedFieldsAreNeverUsableInSubscriptionsOrIndexes() {
    for (table, queryable) in RecordMapper.queryableColumns {
      #expect(queryable.isDisjoint(with: RecordMapper.encryptedColumns[table] ?? []), "加密字段服务端看不见，不能建索引或做订阅谓词")
    }
  }
}
