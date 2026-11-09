import CueStore
import Foundation
import Testing

@Suite struct PreviewTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  private func file(_ name: String, _ text: String) throws -> URL {
    let url = fixture.directory.appending(path: "src-\(UUID().uuidString)").appending(path: name)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    return url
  }

  @Test func aLaterBatchNeverSharesACreationTimeWithAnEarlierOneInTheSameSession() async throws {
    let first = try await store.addPreviews([file("a.png", "a"), file("b.png", "b")].map { (url: $0, title: $0.lastPathComponent) }, sessionID: "s1").map(\.preview)
    let ahead = first[0].createdAt.addingTimeInterval(60)
    try RawDB(fixture.url).exec("UPDATE previews SET createdAt = \(Int64(ahead.timeIntervalSince1970 * 1000))")

    let next = try await store.addPreviews([file("c.png", "c"), file("d.png", "d")].map { (url: $0, title: $0.lastPathComponent) }, sessionID: "s1").map(\.preview)
    let elsewhere = try await store.addPreviews([file("e.png", "e")].map { (url: $0, title: $0.lastPathComponent) }, sessionID: "s2")[0].preview

    #expect(Set(next.map(\.createdAt)).count == 1 && next[0].createdAt > ahead)
    #expect(try await store.previews(of: "s1").map(\.name) == ["a.png", "b.png", "c.png", "d.png"])
    #expect(elsewhere.createdAt < ahead)
  }

  @Test func previewsGoWithTheirQuietSessionAndASharedFileStaysWhileUsed() async throws {
    let now = Date.now
    let longAgo = now.addingTimeInterval(-30 * 86_400)
    for id in ["quiet", "active"] {
      try await store.upsertPiSession(IndexedSession(id: id, path: "/s/\(id).jsonl", cwd: "/w", lastActivityAt: id == "quiet" ? longAgo : now.addingTimeInterval(9 * 86_400)), host: "mac")
      try await store.writePiTranscript(PiTranscript(
        sessionID: id, messages: [PiChatMessage(sessionID: id, entryID: "e", seq: 1, role: .user, text: "x", at: longAgo)], recap: PiRecap()))
    }
    let shared = try await store.addPreviews([file("s.txt", "shared")].map { (url: $0, title: $0.lastPathComponent) }, sessionID: "quiet")[0].preview
    _ = try await store.addPreviews([file("s.txt", "shared")].map { (url: $0, title: $0.lastPathComponent) }, sessionID: "active")
    let only = try await store.addPreviews([file("o.txt", "only")].map { (url: $0, title: $0.lastPathComponent) }, sessionID: "quiet")[0].preview

    try await store.prunePiMessages(olderThan: 7 * 86_400, now: now.addingTimeInterval(8 * 86_400))

    let quiet = try await store.previews(of: "quiet"), active = try await store.previews(of: "active")
    #expect(quiet.isEmpty && active.count == 1)
    let cached = { (key: String) in FileManager.default.fileExists(atPath: store.files.directory.appending(path: key).path) }
    #expect(cached(shared.key) && !cached(only.key))
    #expect(try RawDB(fixture.url).rows("SELECT hash FROM attachments") == [[shared.hash]])
  }
}
