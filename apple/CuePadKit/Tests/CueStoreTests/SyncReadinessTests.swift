import CueStore
import Testing

/// 同步字段与本机字段分表：同步表整行上传到 iCloud，因设备而异的列不能出现在里面。
@Suite struct SyncReadinessTests {
  static let synced = Table.synced.map(\.rawValue)
  let fixture = try! Fixture()
  var raw: RawDB { RawDB(fixture.url) }

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
