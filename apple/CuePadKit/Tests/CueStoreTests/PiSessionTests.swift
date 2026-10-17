import CueStore
import Foundation
import Testing

/// Pi 历史索引的检查点（服务层的不透明字节，含读取偏移与分支树）随会话存在本机表里；偏移不另存一份。
@Suite struct PiSessionTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  private func session(_ id: String = "s1", title: String = "first") -> IndexedSession {
    IndexedSession(id: id, path: "/tmp/\(id).jsonl", cwd: "/work/a", title: title, lastActivityAt: Date())
  }

  /// 含 0 字节、接近 1MB：不能被当成文本截断。
  private func blob(seed: Int) -> Data {
    Data((0..<900_000).map { UInt8(truncatingIfNeeded: ($0 * 31 + seed) % 251) })
  }

  @Test func checkpointRoundTripsByteForByte() async throws {
    let data = blob(seed: 1)
    try await store.upsertPiSession(session(), checkpoint: data, host: "mac-a")
    #expect(try await store.piCheckpoint(of: "s1") == data)

    try await store.upsertPiSession(session(), checkpoint: Data(), host: "mac-a")
    #expect(try await store.piCheckpoint(of: "s1") == Data())
  }

  @Test func metadataUpdatesKeepTheCheckpointAndNewCheckpointsReplaceIt() async throws {
    let first = blob(seed: 1)
    try await store.upsertPiSession(session(), checkpoint: first, host: "mac-a")

    try await store.upsertPiSession(session(title: "renamed"), host: "mac-a")  // 只更新元数据
    #expect(try await store.piCheckpoint(of: "s1") == first)
    #expect(try await store.piSessions().map(\.title) == ["renamed"])

    let second = blob(seed: 2)
    try await store.upsertPiSession(session(title: "renamed"), checkpoint: second, host: "mac-a")
    #expect(try await store.piCheckpoint(of: "s1") == second)
    #expect(try await store.piSessions().count == 1)
  }
}
