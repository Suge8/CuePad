import CueStore
import CueTestSupport
import Foundation
import Testing

@Suite struct PiTranscriptStoreTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  private func message(_ sessionID: String, _ entry: String, at: Date) -> PiChatMessage {
    PiChatMessage(sessionID: sessionID, entryID: entry, seq: 1, role: .user, text: entry, at: at)
  }

  /// 会话 7 天没有活动（按会话文件里的最后活动，不按最后一条消息）、对话也是 7 天前写出的才删；按需补写的旧会话写出后留够 7 天。
  @Test func messagesArePrunedOnlyWhenTheSessionIsQuietAndTheyWereWrittenLongAgo() async throws {
    let now = Date.now
    let longAgo = now.addingTimeInterval(-30 * 86_400)
    for (id, activity) in [("quiet", longAgo), ("active", now.addingTimeInterval(7 * 86_400))] {
      try await store.upsertPiSession(PiSession(id: id, path: "/s/\(id).jsonl", cwd: "/w", lastActivityAt: activity), host: "mac")
      // 两个会话的消息都很旧：active 只是之后没有新消息，文件里仍有别的活动
      try await store.writePiTranscript(PiTranscript(sessionID: id, messages: [message(id, id, at: longAgo)], recap: PiRecap()))
    }

    try await store.prunePiMessages(olderThan: 7 * 86_400, now: now)
    #expect(try await store.piMessages(of: "quiet").count == 1)  // 刚补写的：留着

    try await store.prunePiMessages(olderThan: 7 * 86_400, now: now.addingTimeInterval(8 * 86_400))
    #expect(try await store.piMessages(of: "quiet").isEmpty)
    #expect(try await store.piMessages(of: "active").count == 1)  // 会话还在活动：消息再旧也留着
  }

}
