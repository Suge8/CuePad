import CueStore
import CueText
import Foundation
import Testing

@Suite struct PiTranscriptStoreTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  private func message(_ sessionID: String, _ entry: String, at: Date) -> PiChatMessage {
    PiChatMessage(sessionID: sessionID, entryID: entry, seq: 1, role: .user, text: entry, at: at)
  }

  @Test func messagesArePrunedOnlyWhenTheSessionIsQuietAndTheyWereWrittenLongAgo() async throws {
    let now = Date.now
    let longAgo = now.addingTimeInterval(-30 * 86_400)
    for (id, activity) in [("quiet", longAgo), ("active", now.addingTimeInterval(7 * 86_400))] {
      try await store.upsertPiSession(IndexedSession(id: id, path: "/s/\(id).jsonl", cwd: "/w", lastActivityAt: activity), host: "mac")
      // 两个会话的消息都很旧：active 只是之后没有新消息，文件里仍有别的活动
      try await store.writePiTranscript(PiTranscript(sessionID: id, messages: [message(id, id, at: longAgo)], recap: PiRecap()))
    }

    try await store.prunePiMessages(olderThan: 7 * 86_400, now: now)
    #expect(try await store.piMessages(of: "quiet").count == 1)  // 刚补写的：留着

    try await store.prunePiMessages(olderThan: 7 * 86_400, now: now.addingTimeInterval(8 * 86_400))
    #expect(try await store.piMessages(of: "quiet").isEmpty)
    #expect(try await store.piMessages(of: "active").count == 1)  // 会话还在活动：消息再旧也留着
  }

  @Test func imagesInMessagesAreRegisteredAndReclaimedWithTheConversation() async throws {
    let now = Date.now
    let longAgo = now.addingTimeInterval(-30 * 86_400)
    let only = try store.files.store(pngData(width: 8, height: 8, shade: 0.1))
    let shared = try store.files.store(pngData(width: 8, height: 8, shade: 0.9))
    _ = try await store.createCard(body: CueFormat.imageMarkup(key: shared))
    try await store.upsertPiSession(IndexedSession(id: "s", path: "/s/s.jsonl", cwd: "/w", lastActivityAt: longAgo), host: "mac")
    let text = "看\n\(CueFormat.imageMarkup(key: only))\n\(CueFormat.imageMarkup(key: shared))"
    try await store.writePiTranscript(
      PiTranscript(sessionID: "s", messages: [PiChatMessage(sessionID: "s", entryID: "u", seq: 1, role: .user, text: text, at: longAgo)], recap: PiRecap()))
    #expect(try await store.hasAttachment(only))

    try await store.prunePiMessages(olderThan: 7 * 86_400, now: now.addingTimeInterval(8 * 86_400))

    let cached = { (key: String) in FileManager.default.fileExists(atPath: store.files.directory.appending(path: key).path) }
    #expect(try await !store.hasAttachment(only) && !cached(only))
    #expect(try await store.hasAttachment(shared) && cached(shared))
  }

  @Test func clippingKeepsImageReferencesWhole() {
    let reference = CueFormat.imageMarkup(key: String(repeating: "a", count: 64))
    let message = PiChatMessage(
      sessionID: "s", entryID: "u", seq: 1, role: .user, text: String(repeating: "字", count: PiChatMessage.textLimit + 50) + "\n" + reference, at: .now)
    #expect(message.text.hasSuffix("…" + reference))
    #expect(CueFormat.attachmentKeys(in: message.text) == [String(repeating: "a", count: 64)])
    #expect(CueFormat.plainText(message.text).count == PiChatMessage.textLimit)
  }
}
