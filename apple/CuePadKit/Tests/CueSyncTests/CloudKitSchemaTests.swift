import CueStore
import Foundation
import Testing

@testable import CueSync

/// CloudKit 数据结构（.ckdb）是记录映射的派生物：生成器读同步表的真实列类型、`RecordMapper` 的加密声明与订阅谓词用到的字段。
/// 仓库里提交的 `apple/CloudKit/cuepad.ckdb` 必须与生成结果一致；映射变了这里会失败，按提示重新生成并导入。
/// 设了 `CUEPAD_REGENERATE_SCHEMA=1` 时不比对，把生成结果写进那个文件。
@Suite struct CloudKitSchemaTests {
  static let regenerating = ProcessInfo.processInfo.environment["CUEPAD_REGENERATE_SCHEMA"] == "1"

  /// apple/CuePadKit/Tests/CueSyncTests/<this file> → apple/CloudKit/cuepad.ckdb
  static var schemaFile: URL {
    URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "CloudKit/cuepad.ckdb")
  }

  @Test func committedSchemaFileMatchesTheRecordMapping() async throws {
    let generated = try await CloudKitSchema.generate()
    if Self.regenerating { return try generated.write(to: Self.schemaFile, atomically: true, encoding: .utf8) }
    let committed = try String(contentsOf: Self.schemaFile, encoding: .utf8)
    #expect(generated == committed, "记录映射变了：运行 TEST_RUNNER_CUEPAD_REGENERATE_SCHEMA=1 apple/scripts/xc.sh test kit -only-testing:CueSyncTests/CloudKitSchemaTests 重新生成，再用 cktool import-schema 导入（见 docs/release.md「CloudKit 数据结构」）")
  }

  @Test func encryptedFieldsAreNeverUsableInSubscriptionsOrIndexes() {
    for (table, queryable) in AlertSubscriptions.queriedColumns {
      #expect(queryable.isDisjoint(with: RecordMapper.encryptedColumns[table] ?? []), "加密字段服务端看不见，不能建索引或做订阅谓词")
    }
  }
}
