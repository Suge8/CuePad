import CryptoKit
import CueStore
import Foundation
import Testing

/// 图片文件经 `files` 同步写入（不经 actor），附件记录（同步用）在引用它的写入里登记。
@Suite struct AttachmentFileTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }
  var attachmentsDirectory: URL { fixture.directory.appending(path: "Attachments", directoryHint: .isDirectory) }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func records() throws -> [[String]] {
    try RawDB(fixture.url).rows("SELECT hash, byteCount, format FROM attachments ORDER BY hash")
  }

  @Test func storingImageKeepsFileByContentHashAndDedupes() throws {
    let data = pngData(width: 40, height: 20)
    let first = try store.files.store(data)
    let again = try store.files.store(data)
    let other = try store.files.store(pngData(width: 40, height: 20, shade: 0.9))

    #expect(first == sha256(data) && again == first && other != first)
    #expect(try Data(contentsOf: attachmentsDirectory.appending(path: first)) == data)
    #expect(try FileManager.default.contentsOfDirectory(atPath: attachmentsDirectory.path).count == 2)
  }

  @Test func storingFromFileGivesTheSameHashAndBytes() throws {
    let data = pngData(width: 30, height: 30)
    let source = fixture.directory.appending(path: "dropped.png")
    try data.write(to: source)

    let hash = try store.files.store(fileAt: source)

    #expect(hash == sha256(data))
    #expect(try store.files.original(hash: hash) == data)
    #expect(try FileManager.default.contentsOfDirectory(atPath: attachmentsDirectory.path) == [hash])
  }

  @Test func nonImageIsRejectedAndLeavesNothingBehind() throws {
    let source = fixture.directory.appending(path: "notes.txt")
    try Data("not an image".utf8).write(to: source)

    #expect(throws: CueStoreError.notAnImage) { try store.files.store(Data("not an image".utf8)) }
    #expect(throws: CueStoreError.notAnImage) { try store.files.store(fileAt: source) }
    let left = (try? FileManager.default.contentsOfDirectory(atPath: attachmentsDirectory.path)) ?? []
    #expect(left.isEmpty)
  }

  @Test func referencingStoredImageRegistersOneAttachmentRecord() async throws {
    let data = pngData(width: 12, height: 12)
    let hash = try store.files.store(data)
    #expect(try records().isEmpty)  // 没被引用的图片不登记、不上传

    let card = try await store.createCard(in: nil, body: "看 ![](cuepad://img/\(hash))")
    _ = try await store.createCard(in: nil, body: "![](cuepad://img/\(hash)) 又一次")
    #expect(try records() == [[hash, "\(data.count)", "png"]])

    let later = try store.files.store(pngData(width: 12, height: 12, shade: 0.1))
    try await store.updateCard(card.id) { $0.body += "\n![](cuepad://img/\(later))" }
    #expect(try records().map { $0[0] } == [hash, later].sorted())
  }

  @Test func deliveryRequestReferencingUnsavedImageRegistersIt() async throws {
    let hash = try store.files.store(pngData(width: 5, height: 5))
    _ = try await store.requestDelivery(
      "刚粘贴 ![](cuepad://img/\(hash))", to: SendTarget(kind: .piSession, name: "pi", ref: "s"), on: "mac")
    #expect(try records().map { $0[0] } == [hash])
  }

  @Test func referenceToImageNotOnThisDeviceRegistersNothing() async throws {
    _ = try await store.createCard(in: nil, body: "![](cuepad://img/\(String(repeating: "a", count: 64)))")
    #expect(try records().isEmpty)
  }

  @Test(arguments: ["../cuepad.db", "deadbeef", String(repeating: "0", count: 64)])
  func unknownOrMalformedHashIsNotFound(hash: String) throws {
    _ = try store.files.store(pngData(width: 4, height: 4))  // 附件目录存在，"../cuepad.db" 才真的指向库文件
    #expect(throws: CueStoreError.notFound) { try store.files.original(hash: hash) }
    #expect(store.files.fileURL(for: hash) == nil)
  }

  @Test func imagesSurviveReopeningTheStore() throws {
    let data = pngData(width: 10, height: 10)
    let hash = try store.files.store(data)
    let reopened = try CueStore(url: fixture.url)
    #expect(try reopened.files.original(hash: hash) == data)
  }
}
