import CueStore
import Foundation
import Testing

/// Pi 历史索引的检查点（服务层的不透明字节，含读取偏移与分支树）随会话存在本机表里；偏移不另存一份。
@Suite struct PiSessionTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  private func session(_ id: String = "s1", title: String = "first") -> PiSession {
    PiSession(id: id, path: "/tmp/\(id).jsonl", cwd: "/work/a", title: title, lastActivityAt: Date())
  }

  /// 含 0 字节、接近 1MB：不能被当成文本截断。
  private func blob(seed: Int) -> Data {
    Data((0..<900_000).map { UInt8(truncatingIfNeeded: ($0 * 31 + seed) % 251) })
  }

  @Test func checkpointRoundTripsByteForByte() async throws {
    let data = blob(seed: 1)
    try await store.upsertPiSession(session(), checkpoint: data)
    #expect(try await store.piCheckpoint(of: "s1") == data)

    try await store.upsertPiSession(session(), checkpoint: Data())
    #expect(try await store.piCheckpoint(of: "s1") == Data())
  }

  @Test func sessionWithoutCheckpointReadsNil() async throws {
    try await store.upsertPiSession(session())
    #expect(try await store.piCheckpoint(of: "s1") == nil)
    #expect(try await store.piCheckpoint(of: "unknown") == nil)
  }

  @Test func metadataUpdatesKeepTheCheckpointAndNewCheckpointsReplaceIt() async throws {
    let first = blob(seed: 1)
    try await store.upsertPiSession(session(), checkpoint: first)

    try await store.upsertPiSession(session(title: "renamed"))  // 只更新元数据
    #expect(try await store.piCheckpoint(of: "s1") == first)
    #expect(try await store.piSessions().map(\.title) == ["renamed"])

    let second = blob(seed: 2)
    try await store.upsertPiSession(session(title: "renamed"), checkpoint: second)
    #expect(try await store.piCheckpoint(of: "s1") == second)
    #expect(try await store.piSessions().count == 1)
  }

  @Test func sessionListStaysCheapAndOrderedByActivity() async throws {
    let old = PiSession(id: "old", path: "/o", cwd: "/w", lastActivityAt: Date(timeIntervalSince1970: 100))
    let recent = PiSession(id: "new", path: "/n", cwd: "/w", lastActivityAt: Date(timeIntervalSince1970: 200))
    try await store.upsertPiSession(old, checkpoint: blob(seed: 1))
    try await store.upsertPiSession(recent, checkpoint: blob(seed: 2))
    #expect(try await store.piSessions().map(\.id) == ["new", "old"])
  }

  @Test func developmentDatabaseWithReadOffsetColumnUpgrades() async throws {
    let url = fixture.directory.appending(path: "old/cuepad.db")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try RawDB(url).exec(
      """
      CREATE TABLE piSessions (
        id TEXT PRIMARY KEY NOT NULL, path TEXT NOT NULL, cwd TEXT NOT NULL, title TEXT NOT NULL,
        lastActivityAt INTEGER NOT NULL, readOffset INTEGER NOT NULL
      ) STRICT;
      CREATE TABLE cards (id TEXT PRIMARY KEY NOT NULL) STRICT;
      INSERT INTO piSessions VALUES ('legacy', '/p', '/c', 't', 1000, 4096);
      PRAGMA user_version = 2;
      """)

    let upgraded = try CueStore(url: url)

    #expect(try await upgraded.piSessions().map(\.id) == ["legacy"])
    #expect(try await upgraded.piCheckpoint(of: "legacy") == nil)  // 旧偏移作废，该会话重新索引
    let columns = try RawDB(url).rows("SELECT name FROM pragma_table_info('piSessions')").map { $0[0] }
    #expect(columns.contains("checkpoint") && !columns.contains("readOffset"))
  }
}
