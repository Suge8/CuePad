import CueStore
import Foundation
import Testing

/// 由 CueSync 把同步表映射为 CKRecord（record type = 表名，recordName = id）。
/// 这些约束让映射不必改表结构：单列 TEXT 主键、每条记录有 modifiedAt、没有外键与唯一约束、
/// 只用 CKRecord 能直接存的列类型、同步字段与本机字段分表。
@Suite struct SyncReadinessTests {
  static let synced = [
    "projects", "cards", "sendRecords", "attachments", "piSessionStates", "agentCatalogs", "deliveryRequests", "directoryBindings",
    "piMessages", "previews", "accountQuotas", "cueMessages", "cueLines", "cueProfile", "cueState", "cueRead", "macPresence", "macAgents", "sessionViewers",
  ]
  static let local = ["piSessions", "piProcesses", "writeCounter", "projectDirectories", "syncRecords", "syncState", "cueSummaries"]
  let fixture = try! Fixture()
  var raw: RawDB { RawDB(fixture.url) }

  @Test func everyTableIsClassifiedAsSyncedOrLocal() throws {
    let tables = try raw.rows(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'searchIndex%'"
    ).map { $0[0] }
    #expect(Set(tables) == Set(Self.synced + Self.local))
  }

  /// Pi 索引与偏移、项目绑定的代码目录（路径因设备而异）只在本机表，同步表不带这些列。
  @Test func deviceSpecificFieldsLiveOnlyInLocalTables() throws {
    for table in Self.synced {
      let columns = try raw.rows("SELECT name FROM pragma_table_info('\(table)')").map { $0[0] }
      #expect(!columns.contains("checkpoint") && !columns.contains("cwd") && !columns.contains("directory"))
    }
    let sessions = try raw.rows("SELECT name FROM pragma_table_info('piSessions')").map { $0[0] }
    #expect(sessions.contains("checkpoint") && sessions.contains("cwd"))
    let directories = try raw.rows("SELECT name FROM pragma_table_info('projectDirectories')").map { $0[0] }
    #expect(directories.contains("projectID") && directories.contains("directory"))
  }
}
