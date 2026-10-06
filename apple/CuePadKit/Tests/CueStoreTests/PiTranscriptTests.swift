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

  /// 会话 7 天没有活动、对话也是 7 天前写出的才删；按需补写的旧会话写出后留够 7 天。
  @Test func messagesArePrunedOnlyWhenTheSessionIsQuietAndTheyWereWrittenLongAgo() async throws {
    let now = Date.now
    try await store.writePiTranscript(PiTranscript(sessionID: "quiet", messages: [message("quiet", "q", at: now.addingTimeInterval(-30 * 86_400))], recap: PiRecap()))
    try await store.writePiTranscript(PiTranscript(sessionID: "busy", messages: [message("busy", "b", at: now)], recap: PiRecap()))

    try await store.prunePiMessages(olderThan: 7 * 86_400, now: now)
    #expect(try await store.piMessages(of: "quiet").count == 1)  // 刚补写的：留着

    try await store.prunePiMessages(olderThan: 7 * 86_400, now: now.addingTimeInterval(8 * 86_400))
    #expect(try await store.piMessages(of: "quiet").isEmpty)
    #expect(try await store.piMessages(of: "busy").isEmpty)  // 8 天后它也安静了
  }

  @Test func overlongTextIsCutAtTheLimit() {
    let message = PiChatMessage(sessionID: "s", entryID: "e", seq: 1, role: .pi, text: String(repeating: "长", count: 9_000), at: .now)
    #expect(message.text.count == PiChatMessage.textLimit && message.text.hasSuffix("…"))
  }
}
