import CloudKit
import CryptoKit
import CueStore
import Foundation
import Testing

@testable import CueSync

@Suite struct AttachmentSyncTests {
  let rig = try! Rig()
  var store: CueStore { rig.store }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func assetFile(_ data: Data) throws -> URL {
    let url = rig.fixture.directory.appending(path: "download-\(UUID().uuidString)")
    try data.write(to: url)
    return url
  }

  private func attachmentFields(hash: String, byteCount: Int) -> [String: SQLValue] {
    [
      "hash": .text(hash), "byteCount": .int(Int64(byteCount)), "format": .text("png"),
      "createdAt": .int(1_000), "modifiedAt": .int(5_000),
    ]
  }

  /// 存入图片并在卡片里引用它（引用时登记附件记录），返回哈希与附件记录的 id。
  private func referencedImage(_ data: Data) async throws -> (hash: String, id: String) {
    let hash = try store.files.store(data)
    _ = try await store.createCard(body: "![](cuepad://img/\(hash))")
    let id = try #require(try RawDB(rig.fixture.url).rows("SELECT id FROM attachments WHERE hash = '\(hash)'").first?[0])
    return (hash, id)
  }

  private func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: testZone) }

  @Test func pushedAttachmentRecordCarriesTheFileAsAnAsset() async throws {
    let data = pngData(width: 6, height: 6)
    let attachment = try await referencedImage(data)

    let record = try #require(try await rig.coordinator.record(for: recordID(attachment.id)))

    #expect(record["hash"] as? String == attachment.hash)
    let asset = try #require(record["file"] as? CKAsset)
    #expect(try Data(contentsOf: try #require(asset.fileURL)) == data)
  }

  @Test func attachmentWhoseFileIsMissingIsNotPushed() async throws {
    let attachment = try await referencedImage(pngData(width: 3, height: 3))
    try FileManager.default.removeItem(at: try #require(store.files.fileURL(for: attachment.hash)))
    #expect(try await rig.coordinator.record(for: recordID(attachment.id)) == nil)
  }
  @Test func downloadedAssetIsAdoptedIntoTheAttachmentDirectoryByHash() async throws {
    let data = pngData(width: 9, height: 9)
    let hash = sha256(data)
    let record = remoteRecord(.attachments, attachmentFields(hash: hash, byteCount: data.count))
    record["file"] = CKAsset(fileURL: try assetFile(data))
    try await rig.simulatePush()  // 新库的默认项目先传上去

    try await rig.coordinator.pulled([record], [])

    #expect(try store.files.original(hash: hash) == data)
    #expect(try RawDB(rig.fixture.url).count("attachments") == 1)
    #expect(try await rig.reconcileDelta().saves.isEmpty)
  }

  @Test func corruptOrMissingAssetIsRejectedAndReported() async throws {
    let data = pngData(width: 9, height: 9)
    let hash = sha256(data)

    let corrupt = remoteRecord(.attachments, attachmentFields(hash: hash, byteCount: data.count))
    corrupt["file"] = CKAsset(fileURL: try assetFile(Data("tampered".utf8)))
    let missing = remoteRecord(.attachments, attachmentFields(hash: sha256(Data("other".utf8)), byteCount: 5))

    try await rig.coordinator.pulled([corrupt, missing], [])

    #expect(try RawDB(rig.fixture.url).count("attachments") == 0)
    #expect(throws: CueStoreError.notFound) { try store.files.original(hash: hash) }
    #expect(try RawDB(rig.fixture.url).count("syncRecords") == 0)
    #expect(await rig.coordinator.issues.count == 2)
  }

  @Test func remoteAttachmentDeletionRemovesTheFileUnlessACardStillReferencesIt() async throws {
    let free = try await referencedImage(pngData(width: 4, height: 4, shade: 0.1))
    let used = try await referencedImage(pngData(width: 4, height: 4, shade: 0.9))
    let freeCard = try #require(try await store.cards(in: Project.defaultID).first { $0.body.contains(free.hash) })
    try await store.updateCard(freeCard.id) { $0.body = "图片删掉了" }
    try await rig.simulatePush()

    try await rig.coordinator.pulled(
      [], [(recordID(free.id), "attachments"), (recordID(used.id), "attachments")])

    #expect(throws: CueStoreError.notFound) { try store.files.original(hash: free.hash) }
    #expect(try !store.files.original(hash: used.hash).isEmpty)
    #expect(try RawDB(rig.fixture.url).count("attachments") == 0)
  }
}
