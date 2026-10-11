import CueStore
import CueTestSupport
import Foundation
import Testing

/// Agent 发到手机上看的文件（HTML、图片、PDF、Markdown、文本）：按内容哈希存进附件目录，预览记录属于某个 Pi 会话。
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

    await #expect(throws: CueStoreError.previewUnreadable(missing.path)) { try await store.addPreview(fileAt: missing, title: nil, sessionID: "s1") }
    await #expect(throws: CueStoreError.previewUnreadable(folder.path)) { try await store.addPreview(fileAt: folder, title: nil, sessionID: "s1") }
    await #expect(throws: CueStoreError.previewUnsupported("zip")) { try await store.addPreview(fileAt: archive, title: nil, sessionID: "s1") }
    await #expect(throws: CueStoreError.previewTooLarge(limit: PiPreview.maxBytes)) { try await store.addPreview(fileAt: big, title: nil, sessionID: "s1") }

    let stored = try await store.previews(of: "s1")
    let records = try RawDB(fixture.url).count("attachments")
    #expect(stored.isEmpty && files().isEmpty && records == 0)
  }

  /// 会话安静够久、对话被清掉时，它的预览和文件一起清；还有别的预览用着同一份文件的留着。
  @Test func previewsGoWithTheirQuietSessionAndASharedFileStaysWhileUsed() async throws {
    let now = Date.now
    let longAgo = now.addingTimeInterval(-30 * 86_400)
    for id in ["quiet", "active"] {
      try await store.upsertPiSession(PiSession(id: id, path: "/s/\(id).jsonl", cwd: "/w", lastActivityAt: id == "quiet" ? longAgo : now.addingTimeInterval(9 * 86_400)), host: "mac")
      try await store.writePiTranscript(PiTranscript(
        sessionID: id, messages: [PiChatMessage(sessionID: id, entryID: "e", seq: 1, role: .user, text: "x", at: longAgo)], recap: PiRecap()))
    }
    let shared = try await store.addPreview(fileAt: file("s.txt", "shared"), title: nil, sessionID: "quiet").preview
    _ = try await store.addPreview(fileAt: file("s.txt", "shared"), title: nil, sessionID: "active")
    let only = try await store.addPreview(fileAt: file("o.txt", "only"), title: nil, sessionID: "quiet").preview

    try await store.prunePiMessages(olderThan: 7 * 86_400, now: now.addingTimeInterval(8 * 86_400))

    let quiet = try await store.previews(of: "quiet"), active = try await store.previews(of: "active")
    #expect(quiet.isEmpty && active.count == 1)
    #expect(store.files.fileURL(for: shared.hash) != nil && store.files.fileURL(for: only.hash) == nil)
    #expect(try RawDB(fixture.url).rows("SELECT hash FROM attachments") == [[shared.hash]])
  }
}
