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

  @Test func addedFileIsKeptByContentHashAndRegisteredForSync() async throws {
    let source = try file("demo.html", "<h1>登录页</h1>")

    let added = try await store.addPreview(fileAt: source, title: "登录页改好了", sessionID: "s1")

    let preview = added.preview
    #expect(preview.sessionID == "s1" && preview.title == "登录页改好了" && preview.name == "demo.html")
    #expect(preview.byteCount == Data("<h1>登录页</h1>".utf8).count && preview.kind == .web)
    #expect(try Data(contentsOf: #require(store.files.fileURL(for: preview.hash))) == Data("<h1>登录页</h1>".utf8))
    #expect(try await store.previews(of: "s1") == [preview])
    #expect(try RawDB(fixture.url).rows("SELECT hash, byteCount FROM attachments") == [[preview.hash, String(preview.byteCount)]])
    #expect(added.outsideReferences.isEmpty)
  }

  @Test func sameContentForAnotherSessionSharesTheFileAndItsRecord() async throws {
    let first = try await store.addPreview(fileAt: file("a.md", "# 报告"), title: nil, sessionID: "s1").preview
    let second = try await store.addPreview(fileAt: file("b.md", "# 报告"), title: nil, sessionID: "s2").preview

    #expect(first.hash == second.hash && first.id != second.id)
    #expect(files() == [first.hash])
    #expect(try RawDB(fixture.url).count("attachments") == 1)
  }

  @Test func titleDefaultsToTheFileNameWithoutItsExtension() async throws {
    let preview = try await store.addPreview(fileAt: file("login-flow.png", "x"), title: "  ", sessionID: "s1").preview
    #expect(preview.title == "login-flow")
  }

  @Test(arguments: [
    ("a.html", PreviewKind.web), ("a.HTM", .web), ("a.svg", .web), ("a.png", .image), ("a.jpeg", .image), ("a.webp", .image),
    ("a.pdf", .pdf), ("a.md", .markdown), ("a.markdown", .markdown), ("a.txt", .text), ("a.json", .text), ("a.csv", .text),
  ])
  func commonTypesHaveAKind(name: String, kind: PreviewKind) {
    #expect(PreviewKind(fileName: name) == kind)
  }

  @Test func refusedFilesSayWhyAndLeaveNothingBehind() async throws {
    let missing = fixture.directory.appending(path: "nope.html")
    let folder = fixture.directory.appending(path: "folder.html")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let archive = try file("a.zip", "zip")
    let big = try file("big.pdf", String(repeating: "x", count: Preview.maxBytes + 1))

    await #expect(throws: CueStoreError.previewUnreadable(missing.path)) { try await store.addPreview(fileAt: missing, title: nil, sessionID: "s1") }
    await #expect(throws: CueStoreError.previewUnreadable(folder.path)) { try await store.addPreview(fileAt: folder, title: nil, sessionID: "s1") }
    await #expect(throws: CueStoreError.previewUnsupported("zip")) { try await store.addPreview(fileAt: archive, title: nil, sessionID: "s1") }
    await #expect(throws: CueStoreError.previewTooLarge(limit: Preview.maxBytes)) { try await store.addPreview(fileAt: big, title: nil, sessionID: "s1") }

    #expect(try await store.previews(of: "s1").isEmpty && files().isEmpty && (try RawDB(fixture.url).count("attachments")) == 0)
  }

  /// 手机上预览不联网、也读不到 Mac 上的别的文件：页面引用的外部资源会缺失。文件照常存，把缺的列出来让 Agent 改成单文件再发。
  @Test func htmlThatReliesOnOtherFilesIsStoredAndTheMissingOnesAreListed() async throws {
    let html = """
      <link rel="stylesheet" href="style.css"><link rel="icon" href="data:image/png;base64,AAAA">
      <script src='app.js'></script><img src="shots/a.png"><img src="data:image/png;base64,AAAA">
      <script src="https://cdn.example.com/chart.js"></script><a href="other.html">下一页</a><a href="#top">顶部</a>
      """
    let added = try await store.addPreview(fileAt: file("page.html", html), title: nil, sessionID: "s1")
    #expect(added.outsideReferences == ["style.css", "app.js", "shots/a.png", "https://cdn.example.com/chart.js"])
  }

  @Test func previewsAreOldestFirstAndPerSession() async throws {
    let one = try await store.addPreview(fileAt: file("1.txt", "1"), title: nil, sessionID: "s1").preview
    let two = try await store.addPreview(fileAt: file("2.txt", "2"), title: nil, sessionID: "s1").preview
    _ = try await store.addPreview(fileAt: file("3.txt", "3"), title: nil, sessionID: "s2")
    #expect(try await store.previews(of: "s1").map(\.id) == [one.id, two.id])
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

    #expect(try await store.previews(of: "quiet").isEmpty && (try await store.previews(of: "active")).count == 1)
    #expect(store.files.fileURL(for: shared.hash) != nil && store.files.fileURL(for: only.hash) == nil)
    #expect(try RawDB(fixture.url).rows("SELECT hash FROM attachments") == [[shared.hash]])
  }
}
