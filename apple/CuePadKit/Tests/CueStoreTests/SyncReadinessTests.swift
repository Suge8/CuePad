import CueStore
import Testing

@Suite struct SyncReadinessTests {
  static let synced = Table.synced.map(\.rawValue)
  let fixture = try! Fixture()
  var raw: RawDB { RawDB(fixture.url) }

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
