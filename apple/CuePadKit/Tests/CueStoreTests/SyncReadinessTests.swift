import CueStore
import Foundation
import Testing

/// 由 CKSyncEngine 把同步表映射为 CKRecord（record type = 表名，recordName = id）。
/// 这些约束让映射不必改表结构：单列 TEXT 主键、每条记录有 modifiedAt、没有外键与唯一约束、
/// 只用 CKRecord 能直接存的列类型、同步字段与本机字段分表。
@Suite struct SyncReadinessTests {
  static let synced = [
    "projects", "cards", "tasks", "sendRecords", "attachments", "piSessionStates", "deliveryRequests", "directoryBindings",
    "piMessages",
  ]
  static let local = ["piSessions", "projectDirectories", "syncRecords", "syncState"]
  let fixture = try! Fixture()
  var raw: RawDB { RawDB(fixture.url) }

  @Test func everyTableIsClassifiedAsSyncedOrLocal() throws {
    let tables = try raw.rows(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'searchIndex%'"
    ).map { $0[0] }
    #expect(Set(tables) == Set(Self.synced + Self.local))
  }

  @Test(arguments: synced)
  func syncedTableMapsToACKRecord(table: String) throws {
    let columns = try raw.rows("SELECT name, type, \"notnull\", pk FROM pragma_table_info('\(table)')")
    let primaryKeys = columns.filter { $0[3] != "0" }
    #expect(primaryKeys.map { $0[0] } == ["id"] && primaryKeys.map { $0[1] } == ["TEXT"])
    #expect(columns.contains { $0[0] == "modifiedAt" && $0[1] == "INTEGER" && $0[2] == "1" })
    #expect(columns.allSatisfy { ["TEXT", "INTEGER"].contains($0[1]) })

    #expect(try raw.rows("SELECT 1 FROM pragma_foreign_key_list('\(table)')").isEmpty)
    let uniqueIndexes = try raw.rows(
      "SELECT name FROM pragma_index_list('\(table)') WHERE \"unique\" = 1 AND origin != 'pk'")
    #expect(uniqueIndexes.isEmpty)
  }

  @Test func softDeleteIsJustDeletedAt() throws {
    for table in ["projects", "cards"] {
      let columns = try raw.rows("SELECT name FROM pragma_table_info('\(table)')").map { $0[0] }
      #expect(columns.contains("deletedAt"))
      #expect(!columns.contains { $0.lowercased().contains("batch") || $0.lowercased().contains("deletesource") })
    }
  }

  /// Pi 索引与偏移、项目绑定的代码目录（路径因设备而异）只在本机表，同步表不带这些列。
  @Test func deviceSpecificFieldsLiveOnlyInLocalTables() throws {
    for table in Self.synced {
      let columns = try raw.rows("SELECT name FROM pragma_table_info('\(table)')").map { $0[0] }
      #expect(!columns.contains("checkpoint") && !columns.contains("cwd") && !columns.contains("directory"))
    }
    let sessions = try raw.rows("SELECT name FROM pragma_table_info('piSessions')").map { $0[0] }
    #expect(sessions.contains("checkpoint") && sessions.contains("cwd") && !sessions.contains("readOffset"))
    let directories = try raw.rows("SELECT name FROM pragma_table_info('projectDirectories')").map { $0[0] }
    #expect(directories.contains("projectID") && directories.contains("directory"))
  }

  @Test func recordsGetLowercaseUUIDTextIDsAndModifiedAtAdvancesOnEdit() async throws {
    let store = fixture.store
    let card = try await store.createCard(in: nil, body: "a")
    #expect(try raw.rows("SELECT id FROM cards")[0][0] == card.id.uuidString.lowercased())

    try await Task.sleep(for: .milliseconds(5))
    try await store.updateCard(card.id) { $0.body = "b" }
    let edited = try #require(try await store.card(card.id))
    #expect(edited.modifiedAt > card.modifiedAt && edited.createdAt == card.createdAt)
  }
}
