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

  @Test func pushedAttachmentRecordCarriesTheFileAsAnAsset() async throws {
    let data = pngData(width: 6, height: 6)
    let attachment = try await store.addImage(data)

    let record = try #require(await rig.coordinator.record(for: rig.recordID(attachment.id)))

    #expect(record["hash"] as? String == attachment.hash)
    let asset = try #require(record["file"] as? CKAsset)
    #expect(try Data(contentsOf: try #require(asset.fileURL)) == data)
  }

  @Test func attachmentWhoseFileIsMissingIsNotPushed() async throws {
    let attachment = try await store.registerAttachment(hash: String(repeating: "b", count: 64), byteCount: 1, format: "png")
    #expect(await rig.coordinator.record(for: rig.recordID(attachment.id)) == nil)
  }

  @Test func downloadedAssetIsAdoptedIntoTheAttachmentDirectoryByHash() async throws {
    let data = pngData(width: 9, height: 9)
    let hash = sha256(data)
    let record = remoteRecord(.attachments, attachmentFields(hash: hash, byteCount: data.count))
    record["file"] = CKAsset(fileURL: try assetFile(data))

    await rig.coordinator.handle(.fetched(modifications: [record], deletions: []))

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

    await rig.coordinator.handle(.fetched(modifications: [corrupt, missing], deletions: []))

    #expect(try RawDB(rig.fixture.url).count("attachments") == 0)
    #expect(throws: CueStoreError.notFound) { try store.files.original(hash: hash) }
    #expect(try RawDB(rig.fixture.url).count("syncRecords") == 0)
    #expect(await rig.coordinator.issues.count == 2)
  }

  @Test func remoteAttachmentDeletionRemovesTheFileUnlessACardStillReferencesIt() async throws {
    let free = try await store.addImage(pngData(width: 4, height: 4, shade: 0.1))
    let used = try await store.addImage(pngData(width: 4, height: 4, shade: 0.9))
    _ = try await store.createCard(in: nil, body: "![](cuepad://img/\(used.hash))")
    try await rig.coordinator.reconcile()
    try await rig.simulatePush()

    await rig.coordinator.handle(.fetched(
      modifications: [], deletions: [(rig.recordID(free.id), "attachments"), (rig.recordID(used.id), "attachments")]))

    #expect(throws: CueStoreError.notFound) { try store.files.original(hash: free.hash) }
    #expect(try !store.files.original(hash: used.hash).isEmpty)
    #expect(try RawDB(rig.fixture.url).count("attachments") == 0)
  }
}
