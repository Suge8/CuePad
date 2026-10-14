import CueStore
import CueTestSupport
import Foundation
import Testing

/// Agent 发到手机上看的文件：按内容哈希存进附件目录，预览记录属于某个 Agent 会话。
@Suite struct PreviewTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }
  var attachmentsDirectory: URL { fixture.directory.appending(path: "Attachments", directoryHint: .isDirectory) }

  private func file(_ name: String, _ text: String) throws -> URL {
    let url = fixture.directory.appending(path: "src-\(UUID().uuidString)").appending(path: name)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    return url
  }

  private func files() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: attachmentsDirectory.path)) ?? [] }

  @Test func refusedFilesSayWhyAndLeaveNothingBehind() async throws {
    let missing = fixture.directory.appending(path: "nope.html")
    let folder = fixture.directory.appending(path: "folder.html")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let archive = try file("a.zip", "zip")
    let big = try file("big.pdf", String(repeating: "x", count: PiPreview.maxBytes + 1))

    let fine = try file("fine.png", "png")
    // 一批里有一个不行，整批都不留
    await #expect(throws: CueStoreError.previewUnreadable(missing.path)) { try await store.addPreviews(filesAt: [fine, missing], title: nil, sessionID: "s1") }
    await #expect(throws: CueStoreError.previewUnreadable(folder.path)) { try await store.addPreviews(filesAt: [folder], title: nil, sessionID: "s1") }
    await #expect(throws: CueStoreError.previewUnsupported("zip")) { try await store.addPreviews(filesAt: [fine, archive], title: nil, sessionID: "s1") }
    await #expect(throws: CueStoreError.previewTooLarge(big.path, limit: PiPreview.maxBytes)) { try await store.addPreviews(filesAt: [big], title: nil, sessionID: "s1") }

    let stored = try await store.previews(of: "s1")
    let records = try RawDB(fixture.url).count("attachments")
    #expect(stored.isEmpty && files().isEmpty && records == 0)
  }

  /// 同一批 = 同一创建时间：同一会话里后发的一批即使时钟落在已有预览当时或之前（同一毫秒、时钟回拨），也排在它之后 1 毫秒，不与它合成一张卡；
  /// 别的会话不受影响。
  @Test func aLaterBatchNeverSharesACreationTimeWithAnEarlierOneInTheSameSession() async throws {
    let first = try await store.addPreviews(filesAt: [file("a.png", "a"), file("b.png", "b")], title: nil, sessionID: "s1").map(\.preview)
    let ahead = first[0].createdAt.addingTimeInterval(60)
    try RawDB(fixture.url).exec("UPDATE previews SET createdAt = \(Int64(ahead.timeIntervalSince1970 * 1000))")

    let next = try await store.addPreviews(filesAt: [file("c.png", "c"), file("d.png", "d")], title: nil, sessionID: "s1").map(\.preview)
    let elsewhere = try await store.addPreviews(filesAt: [file("e.png", "e")], title: nil, sessionID: "s2")[0].preview

    #expect(next.allSatisfy { $0.createdAt == ahead.addingTimeInterval(0.001) })
    #expect(try await store.previews(of: "s1").map(\.name) == ["a.png", "b.png", "c.png", "d.png"])
    #expect(elsewhere.createdAt < ahead)
  }

  /// 会话安静够久、对话被清掉时，它的预览和文件一起清；还有别的预览用着同一份文件的留着。
  @Test func previewsGoWithTheirQuietSessionAndASharedFileStaysWhileUsed() async throws {
    let now = Date.now
    let longAgo = now.addingTimeInterval(-30 * 86_400)
    for id in ["quiet", "active"] {
      try await store.upsertPiSession(IndexedSession(id: id, path: "/s/\(id).jsonl", cwd: "/w", lastActivityAt: id == "quiet" ? longAgo : now.addingTimeInterval(9 * 86_400)), host: "mac")
      try await store.writePiTranscript(PiTranscript(
        sessionID: id, messages: [PiChatMessage(sessionID: id, entryID: "e", seq: 1, role: .user, text: "x", at: longAgo)], recap: PiRecap()))
    }
    let shared = try await store.addPreviews(filesAt: [file("s.txt", "shared")], title: nil, sessionID: "quiet")[0].preview
    _ = try await store.addPreviews(filesAt: [file("s.txt", "shared")], title: nil, sessionID: "active")
    let only = try await store.addPreviews(filesAt: [file("o.txt", "only")], title: nil, sessionID: "quiet")[0].preview

    try await store.prunePiMessages(olderThan: 7 * 86_400, now: now.addingTimeInterval(8 * 86_400))

    let quiet = try await store.previews(of: "quiet"), active = try await store.previews(of: "active")
    #expect(quiet.isEmpty && active.count == 1)
    #expect(store.files.fileURL(for: shared.hash) != nil && store.files.fileURL(for: only.hash) == nil)
    #expect(try RawDB(fixture.url).rows("SELECT hash FROM attachments") == [[shared.hash]])
  }
}
