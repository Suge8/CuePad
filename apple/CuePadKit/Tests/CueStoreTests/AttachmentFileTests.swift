import CryptoKit
import CueStore
import Foundation
import Testing

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
    let earlier = try CueStore(location: .isolated(fixture.directory))
    let result = try await body(earlier)
    earlier.files.endRun()
    return result
  }

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

  @Test func strayFilesGoButReferencedDraftedAndPendingOnesStay() async throws {
    let (stray, used, drafted, edited) = try await inEndedRun { earlier in
      let keys = try [0.1, 0.3, 0.5, 0.9].map { try earlier.files.store(pngData(width: 2, height: 2, shade: $0)) }
      _ = try await earlier.createCard(body: "![](cuepad://file/\(keys[1]))")
      let card = try await earlier.createCard(body: "![](cuepad://file/\(keys[3]))")
      try await earlier.updateCard(card.id) { $0.body = "图删了" }
      try await earlier.purgeCard(card.id)
      return (keys[0], keys[1], keys[2], keys[3])
    }
    let cli = try CueStore(location: .isolated(fixture.directory))
    let pending = try cli.files.store(pngData(width: 2, height: 2, shade: 0.7))

    #expect(try await store.removeStrayFiles(drafts: ["看 ![](cuepad://file/\(drafted))"]) == 2)
    for gone in [stray, edited] {
      #expect(store.files.fileURL(for: gone) == nil && !FileManager.default.fileExists(atPath: backups.appending(path: gone).path))
    }
    #expect(try await !store.hasAttachment(edited))
    try FileManager.default.removeItem(at: cached)
    for kept in [used, drafted] { #expect(store.files.fileURL(for: kept) != nil) }
    _ = try await cli.createCard(body: "![](cuepad://file/\(pending))")
    #expect(try await cli.hasAttachment(pending) && cli.files.fileURL(for: pending) != nil)
  }

  /// 别处来的记录不收：收了会把删除同步出去，那台的图就没了。
  @Test func recordFromElsewhereArrivingBeforeItsCardSurvivesCleanup() async throws {
    let other = try Fixture()
    let key = try other.store.files.store(pngData(width: 9, height: 9, shade: 0.42))
    let card = try await other.store.createCard(body: "看 ![](cuepad://file/\(key))")
    let record = try #require(try RawDB(other.url).rows("SELECT id FROM attachments").first?[0])
    let attachmentRow = try #require(try await other.store.syncRow(recordName: record))
    let cardRow = try #require(try await other.store.syncRow(recordName: card.id.uuidString.lowercased()))

    _ = try await store.applyRemote([.save(attachmentRow, systemFields: Data())])
    _ = try await store.removeStrayFiles(drafts: [])
    _ = try await store.applyRemote([.save(cardRow, systemFields: Data())])
    #expect(try await store.hasAttachment(key))
    #expect(try await store.pendingSync().deletes.isEmpty)
  }

  @Test func cleanupKeepsAnotherDevicesRecordOfTheSameContent() async throws {
    let png = pngData(width: 11, height: 11, shade: 0.33)
    let key = try await inEndedRun { earlier in
      let key = try earlier.files.store(png)
      let card = try await earlier.createCard(body: "![](cuepad://file/\(key))")
      try await earlier.updateCard(card.id) { $0.body = "图删了" }
      try await earlier.purgeCard(card.id)
      return key
    }
    let other = try Fixture()
    _ = try other.store.files.store(png)
    let card = try await other.store.createCard(body: "看 ![](cuepad://file/\(key))")
    let theirs = try #require(try RawDB(other.url).rows("SELECT id FROM attachments").first?[0])
    _ = try await store.applyRemote([.save(try #require(try await other.store.syncRow(recordName: theirs)), systemFields: Data())])

    _ = try await store.removeStrayFiles(drafts: [])
    #expect(try RawDB(fixture.url).rows("SELECT id FROM attachments") == [[theirs]])
    #expect(store.files.fileURL(for: key) != nil)
    _ = try await store.applyRemote([.save(try #require(try await other.store.syncRow(recordName: card.id.uuidString.lowercased())), systemFields: Data())])
    #expect(try await store.hasAttachment(key) && store.files.fileURL(for: key) != nil)
  }

  @Test func referencingContentRegisteredElsewhereRegistersOwnRecord() async throws {
    let a = try Fixture()
    let png = pngData(width: 13, height: 13, shade: 0.27)
    let (key, theirs, theirCard) = try await {
      let writer = try CueStore(location: .isolated(a.directory))  // A 上存图建卡的那次运行，随后结束
      let key = try writer.files.store(png)
      let card = try await writer.createCard(body: "![](cuepad://file/\(key))")
      writer.files.endRun()
      return (key, try #require(try RawDB(a.url).rows("SELECT id FROM attachments").first?[0]), card.id)
    }()
    let aCache = a.directory.appending(path: "Caches/CuePadAttachments/\(key)")
    _ = try await store.applyRemote([.save(try #require(try await a.store.syncRow(recordName: theirs)), systemFields: Data())])
    try store.files.adopt(fileAt: aCache, key: key)  // 文件那一路取来
    let card = try await store.createCard(body: "也用 ![](cuepad://file/\(key))")

    try await a.store.updateCard(theirCard) { $0.body = "图删了" }
    try await a.store.purgeCard(theirCard)
    _ = try await a.store.removeStrayFiles(drafts: [])
    #expect(try await !a.store.hasAttachment(key))
    _ = try await store.applyRemote([.delete(SyncKey(table: .attachments, id: theirs))])
    #expect(try await store.hasAttachment(key) && store.files.fileURL(for: key) != nil)

    let mine = try #require(try RawDB(fixture.url).rows("SELECT id FROM attachments").first?[0])
    for name in [mine, card.id.uuidString.lowercased()] {
      _ = try await a.store.applyRemote([.save(try #require(try await store.syncRow(recordName: name)), systemFields: Data())])
    }
    try a.store.files.adopt(fileAt: cached.appending(path: key), key: key)
    #expect(try await a.store.hasAttachment(key) && a.store.files.fileURL(for: key) != nil)
  }

  @Test(arguments: ["../cuepad.db", "deadbeef", String(repeating: "0", count: 64), String(repeating: "0", count: 64) + "./x"])
  func unknownOrMalformedKeyIsNotFound(key: String) throws {
    _ = try store.files.store(pngData(width: 4, height: 4))
    #expect(store.files.fileURL(for: key) == nil)
  }
}
