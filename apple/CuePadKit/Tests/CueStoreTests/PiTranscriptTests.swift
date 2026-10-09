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

  /// 工具活动随回答那条消息存下、原样读回；旧对话（先前没有工具活动）重读会话文件时补上，内容没变就不改写记录。
  @Test func toolActivityIsStoredWithTheReplyAndFilledInWhenAnOldMessageIsWrittenAgain() async throws {
    let at = Date.now
    let tools = PiChatMessage.Tools(
      edits: 1, commands: 1, failed: 1,
      items: [.init(kind: .edit, target: "a.swift", added: 3, removed: 1), .init(kind: .command, target: "swift test", failed: true)])
    func reply(_ tools: PiChatMessage.Tools?) -> PiChatMessage {
      PiChatMessage(sessionID: "s", entryID: "p1", seq: 2, role: .pi, text: "好了", at: at, tools: tools, roundStartedAt: at.addingTimeInterval(-30))
    }
    try await store.writePiTranscript(PiTranscript(sessionID: "s", messages: [reply(nil)], recap: PiRecap()))
    #expect(try await store.piMessages(of: "s").first?.tools == nil)

    try await store.writePiTranscript(PiTranscript(sessionID: "s", messages: [reply(tools)], recap: PiRecap()))
    let filled = try #require(try await store.piMessages(of: "s").first)
    #expect(filled.tools == tools)

    try await store.writePiTranscript(PiTranscript(sessionID: "s", messages: [reply(tools)], recap: PiRecap()))
    #expect(try await store.piMessages(of: "s").first?.modifiedAt == filled.modifiedAt)
  }

  @Test func overlongTextIsCutAtTheLimit() {
    let message = PiChatMessage(sessionID: "s", entryID: "e", seq: 1, role: .pi, text: String(repeating: "长", count: 9_000), at: .now)
    #expect(message.text.count == PiChatMessage.textLimit && message.text.hasSuffix("…"))
  }
}
