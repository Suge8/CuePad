import CryptoKit
import CueStore
import Foundation
import Testing

/// 附件文件经 `files` 同步写入（不经 actor），按键存在缓存目录、上传前在库旁留保底；附件记录（同步用）在引用它的写入里登记。
@Suite struct AttachmentFileTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }
  var cached: URL { fixture.directory.appending(path: "Caches/CuePadAttachments", directoryHint: .isDirectory) }
  var backups: URL { fixture.directory.appending(path: "Attachments", directoryHint: .isDirectory) }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func records() throws -> [[String]] {
    try RawDB(fixture.url).rows("SELECT hash, byteCount, format FROM attachments ORDER BY hash")
  }

  private func file(named name: String, _ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/\(name)")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    return url
  }

  @Test func keyIsContentHashWithExtensionAndSameContentIsStoredOnce() throws {
    let png = pngData(width: 40, height: 20)
    let key = try store.files.store(png)
    #expect(key == sha256(png) + ".png")
    #expect(try store.files.store(png) == key)

    let report = Data("季度数据".utf8)
    #expect(try store.files.store(fileAt: file(named: "Report.PDF", report)) == sha256(report) + ".pdf")
    #expect(try store.files.store(fileAt: file(named: "Makefile", report)) == sha256(report))
    #expect(try store.files.store(fileAt: file(named: "main.ts", report)) == sha256(report) + ".txt")  // 快速查看按文本打开，不当视频
    #expect(try store.files.store(fileAt: file(named: "photo", png)) == key)  // 没有扩展名的图片按内容认

    #expect(try Data(contentsOf: #require(store.files.fileURL(for: key))) == png)
    #expect(store.files.fileURL(for: key)?.deletingLastPathComponent().standardizedFileURL == cached.standardizedFileURL)
  }

  @Test func singleFileOverTheLimitIsRefused() throws {
    let url = try file(named: "huge.mov", Data())
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(AttachmentFiles.maxBytes) + 1)  // 稀疏文件：不真写 500 MB
    try handle.close()
    #expect(throws: CueStoreError.fileTooLarge(limit: AttachmentFiles.maxBytes)) { try store.files.store(fileAt: url) }
  }

  /// 同一个库的另一个进程里做的事，做完它就退出了（持有它存过的文件的那次运行随之结束）。
  private func inEndedRun<T: Sendable>(_ body: (CueStore) async throws -> T) async throws -> T {
    try await body(CueStore(location: .isolated(fixture.directory)))
  }

  /// 缓存可被系统清掉：引用了、服务器还没收下的，存它的进程退出、下次启动清理过之后也由库旁的保底补回；
  /// 收下之后保底删掉，本机没有了就是没有（再从 iCloud 取）。
  @Test func backupCoversClearedCacheUntilUploaded() async throws {
    let key = try await inEndedRun { earlier in
      let key = try earlier.files.store(pngData(width: 6, height: 6))
      _ = try await earlier.createCard(body: "![](cuepad://file/\(key))")
      return key
    }
    _ = try await store.removeStrayFiles(drafts: [])
    try FileManager.default.removeItem(at: cached)
    #expect(store.files.fileURL(for: key) != nil)
    #expect(FileManager.default.fileExists(atPath: cached.appending(path: key).path))

    try await store.attachmentUploaded(try #require(try RawDB(fixture.url).rows("SELECT id FROM attachments").first?[0]))
    try FileManager.default.removeItem(at: cached)
    #expect(store.files.fileURL(for: key) == nil)
  }

  /// 服务器早已收下的内容再存一次（缓存被清后又粘贴了同一张）：引用它时认出记录已在，不再留保底。
  @Test func storingUploadedContentAgainKeepsNoBackupOnceReferenced() async throws {
    let key = try store.files.store(pngData(width: 7, height: 7))
    _ = try await store.createCard(body: "![](cuepad://file/\(key))")
    let id = try #require(try RawDB(fixture.url).rows("SELECT id FROM attachments").first?[0])
    try RawDB(fixture.url).exec("INSERT INTO syncRecords (recordName, recordType, pushedModifiedAt) VALUES ('\(id)', 'attachments', 1)")
    try await store.attachmentUploaded(id)
    try FileManager.default.removeItem(at: cached)

    _ = try store.files.store(pngData(width: 7, height: 7))
    _ = try await store.createCard(body: "又一张 ![](cuepad://file/\(key))")
    #expect(!FileManager.default.fileExists(atPath: backups.appending(path: key).path) && store.files.fileURL(for: key) != nil)
  }

  @Test func referencingStoredFilesRegistersOneRecordPerKey() async throws {
    let png = pngData(width: 12, height: 12)
    let key = try store.files.store(png)
    #expect(try records().isEmpty)  // 没被引用的文件不登记、不上传

    let card = try await store.createCard(body: "看 ![](cuepad://file/\(key))")
    _ = try await store.createCard(body: "![](cuepad://file/\(key)) 又一次")
    #expect(try records() == [[sha256(png), "\(png.count)", "png"]])

    let notes = Data("会议纪要".utf8)
    let doc = try store.files.store(fileAt: file(named: "纪要.docx", notes))
    try await store.updateCard(card.id) { $0.body += "\n[纪要.docx](cuepad://file/\(doc))" }
    #expect(try records().contains([sha256(notes), "\(notes.count)", "docx"]))

    // 发给会话的话里刚粘贴、没存进卡片的同样登记（Mac 要拿到它才发得出去）
    let pasted = try store.files.store(pngData(width: 5, height: 5))
    _ = try await store.requestDelivery("刚粘贴 ![](cuepad://file/\(pasted))", to: SendTarget(kind: .piSession, name: "pi", ref: "s"), on: "mac")
    #expect(try records().count == 3)
  }

  /// 启动时的清理：上次运行（已退出）存下、没有记录、没被正文或草稿引用的才删（缓存与保底一起）；被引用的、草稿里的留着，
  /// 草稿里的从此由这次运行持有，缓存再被清也补得回。还开着的别的进程（命令行）存好、还没提交的不受影响，提交后图在、照常登记。
  @Test func strayFilesGoButReferencedDraftedAndPendingOnesStay() async throws {
    let (stray, used, drafted) = try await inEndedRun { earlier in
      let keys = try [0.1, 0.3, 0.5].map { try earlier.files.store(pngData(width: 2, height: 2, shade: $0)) }
      _ = try await earlier.createCard(body: "![](cuepad://file/\(keys[1]))")
      return (keys[0], keys[1], keys[2])
    }
    let cli = try CueStore(location: .isolated(fixture.directory))
    let pending = try cli.files.store(pngData(width: 2, height: 2, shade: 0.7))

    #expect(try await store.removeStrayFiles(drafts: ["看 ![](cuepad://file/\(drafted))"]) == 1)
    #expect(store.files.fileURL(for: stray) == nil && !FileManager.default.fileExists(atPath: backups.appending(path: stray).path))
    try FileManager.default.removeItem(at: cached)
    for kept in [used, drafted] { #expect(store.files.fileURL(for: kept) != nil) }
    _ = try await cli.createCard(body: "![](cuepad://file/\(pending))")
    #expect(try await cli.hasAttachment(pending) && cli.files.fileURL(for: pending) != nil)
  }

  /// 键来自同步记录：拼不出附件目录外的路径。
  @Test(arguments: ["../cuepad.db", "deadbeef", String(repeating: "0", count: 64), String(repeating: "0", count: 64) + "./x"])
  func unknownOrMalformedKeyIsNotFound(key: String) throws {
    _ = try store.files.store(pngData(width: 4, height: 4))
    #expect(store.files.fileURL(for: key) == nil)
  }
}
