import CryptoKit
import CueStore
import Foundation
import ImageIO
import Testing

@Suite struct AttachmentFileTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }
  var attachmentsDirectory: URL { fixture.directory.appending(path: "Attachments", directoryHint: .isDirectory) }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  @Test func addingImageStoresFileByContentHashAndDedupes() async throws {
    let data = pngData(width: 40, height: 20)
    let first = try await store.addImage(data)
    let again = try await store.addImage(data)
    let other = try await store.addImage(pngData(width: 40, height: 20, shade: 0.9))

    #expect(first.hash == sha256(data) && first.format == "png" && first.byteCount == data.count)
    #expect(again.id == first.id && other.id != first.id)
    #expect(try RawDB(fixture.url).count("attachments") == 2)
    #expect(try Data(contentsOf: attachmentsDirectory.appending(path: first.hash)) == data)
    #expect(try FileManager.default.contentsOfDirectory(atPath: attachmentsDirectory.path).count == 2)
  }

  @Test func originalComesBackByteForByte() async throws {
    let data = pngData(width: 8, height: 8)
    let attachment = try await store.addImage(data)
    #expect(try store.files.original(hash: attachment.hash) == data)
  }

  @Test func thumbnailIsBoundedByMaxPixelAndNeverUpscales() async throws {
    let attachment = try await store.addImage(pngData(width: 400, height: 200))

    let small = try store.files.thumbnail(hash: attachment.hash, maxPixel: 100)
    #expect(small.width == 100 && small.height == 50)

    let unchanged = try store.files.thumbnail(hash: attachment.hash, maxPixel: 1000)
    #expect(unchanged.width == 400 && unchanged.height == 200)
  }

  @Test func nonImageDataIsRejectedAndLeavesNothingBehind() async throws {
    await #expect(throws: CueStoreError.notAnImage) {
      try await store.addImage(Data("not an image".utf8))
    }
    #expect(try RawDB(fixture.url).count("attachments") == 0)
  }

  @Test(arguments: ["../cuepad.db", "deadbeef", String(repeating: "0", count: 64)])
  func unknownOrMalformedHashIsNotFound(hash: String) async throws {
    _ = try await store.addImage(pngData(width: 4, height: 4))  // 附件目录存在，"../cuepad.db" 才真的指向库文件
    #expect(throws: CueStoreError.notFound) { try store.files.original(hash: hash) }
    #expect(throws: CueStoreError.notFound) { try store.files.thumbnail(hash: hash, maxPixel: 50) }
  }

  @Test func imagesSurviveReopeningTheStore() async throws {
    let data = pngData(width: 10, height: 10)
    let attachment = try await store.addImage(data)
    let reopened = try CueStore(url: fixture.url)
    #expect(try reopened.files.original(hash: attachment.hash) == data)
  }
}
