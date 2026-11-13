import CueStore
import Foundation
import Testing

@testable import CueSync

/// 仓库里提交的 `apple/CloudKit/cuepad.ckdb` 必须与生成结果一致；映射变了这里会失败，按提示重新生成并导入。
/// 设了 `CUEPAD_REGENERATE_SCHEMA=1` 时不比对，把生成结果写进那个文件。
@Suite struct CloudKitSchemaTests {
  static let regenerating = ProcessInfo.processInfo.environment["CUEPAD_REGENERATE_SCHEMA"] == "1"

  static var schemaFile: URL {
    URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "CloudKit/cuepad.ckdb")
  }

  @Test func committedSchemaFileMatchesTheRecordMapping() async throws {
    let generated = try await CloudKitSchema.generate()
    if Self.regenerating { return try generated.write(to: Self.schemaFile, atomically: true, encoding: .utf8) }
    let committed = try String(contentsOf: Self.schemaFile, encoding: .utf8)
    #expect(generated == committed, "记录映射变了：运行 TEST_RUNNER_CUEPAD_REGENERATE_SCHEMA=1 apple/scripts/xc.sh test kit -only-testing:CueSyncTests/CloudKitSchemaTests 重新生成，再导入开发环境（apple/CloudKit/AGENTS.md）")
  }

  /// 新加的列不在 `fields` 里选去向（明文、加密、本机）就在这里失败，不会默认以明文进 iCloud。
  @Test func everyColumnOfASyncedTableIsDeclaredExactlyOnce() async throws {
    let store = try Fixture().store
    for table in Table.synced {
      let declared = table.syncedFields.map(\.name) + table.localColumns
      #expect(declared.count == Set(declared).count, "\(table) 有列声明了两次")
      #expect(Set(try await store.columnTypes(of: table).keys) == Set(declared), "\(table) 的列与声明不符")
    }
  }

  @Test func encryptedFieldsAreNeverUsableInSubscriptionsOrIndexes() {
    for (table, queryable) in AlertSubscriptions.queriedColumns {
      let encrypted = table.syncedFields.filter { $0.storage == .encrypted }.map(\.name)
      #expect(queryable.isDisjoint(with: encrypted), "加密字段服务端看不见，不能建索引或做订阅谓词")
    }
  }
}
