import CueStore
import Foundation
import Testing

/// 永久删除卡片时，回收不再被任何卡片正文（含回收站里的卡）引用的附件：记录与文件一起删。
@Suite struct AttachmentReclaimTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }
  var attachmentsDirectory: URL { fixture.directory.appending(path: "Attachments", directoryHint: .isDirectory) }

  private func image(_ shade: CGFloat) async throws -> String {
    try await store.addImage(pngData(width: 8, height: 8, shade: shade)).hash
  }

  private func ref(_ hash: String) -> String { "text ![](cuepad://img/\(hash)) more" }

  private func exists(_ hash: String) throws -> Bool {
    let row = try RawDB(fixture.url).rows("SELECT 1 FROM attachments WHERE hash = '\(hash)'")
    let file = FileManager.default.fileExists(atPath: attachmentsDirectory.appending(path: hash).path)
    #expect(!row.isEmpty == file, "记录与文件必须同在同亡")
    return file
  }

  @Test func purgingCardKeepsImagesOthersStillReferenceAndDropsTheRest() async throws {
    let shared = try await image(0.1)
    let solo = try await image(0.2)
    let doomed = try await store.createCard(in: nil, body: ref(shared) + ref(solo))
    _ = try await store.createCard(in: nil, body: ref(shared))

    try await store.purgeCard(doomed.id)

    #expect(try exists(shared))
    #expect(try !exists(solo))
  }

  @Test func imageReferencedOnlyByTrashedCardSurvivesUntilThatCardIsPurged() async throws {
    let hash = try await image(0.1)
    let kept = try await store.createCard(in: nil, body: ref(hash))
    let other = try await store.createCard(in: nil, body: ref(hash))
    try await store.trashCard(kept.id)

    try await store.purgeCard(other.id)
    #expect(try exists(hash))  // 回收站里的卡还引用它

    try await store.purgeCard(kept.id)
    #expect(try !exists(hash))
  }

  @Test func emptyTrashAndPurgeProjectReclaimTheirCardsImages() async throws {
    let inTrash = try await image(0.1)
    let inProject = try await image(0.2)
    let sharedWithInbox = try await image(0.3)
    let live = try await image(0.4)
    let alone = try await store.createCard(in: nil, body: ref(inTrash))
    let project = try await store.createProject(name: "P", color: "#111")
    _ = try await store.createCard(in: project.id, body: ref(inProject) + ref(sharedWithInbox))
    _ = try await store.createCard(in: nil, body: ref(sharedWithInbox) + ref(live))

    try await store.trashCard(alone.id)
    try await store.emptyTrash()
    #expect(try !exists(inTrash))
    #expect(try exists(inProject))

    try await store.trashProject(project.id)
    try await store.purgeProject(project.id)
    #expect(try !exists(inProject))
    #expect(try exists(sharedWithInbox) && exists(live))
  }

  @Test func imageNotYetInsertedIntoAnyCardIsNotTouchedByUnrelatedPurges() async throws {
    let pending = try await image(0.1)  // 刚粘贴、正文还没保存
    let card = try await store.createCard(in: nil, body: "plain")
    try await store.purgeCard(card.id)
    #expect(try exists(pending))
  }

  @Test func failureToDeleteAFileIsReportedNotSwallowed() async throws {
    let stuck = try await image(0.1)
    let free = try await image(0.2)
    let card = try await store.createCard(in: nil, body: ref(stuck) + ref(free))
    // 只读目录：删不掉文件（不是 root 时）
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: attachmentsDirectory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: attachmentsDirectory.path) }

    await #expect(throws: CueStoreError.attachmentFilesNotRemoved([stuck, free].sorted())) {
      try await store.purgeCard(card.id)
    }

    #expect(try await store.card(card.id) == nil)  // 卡片本身已删除
    #expect(try exists(stuck) && exists(free))  // 删不掉的文件保留记录，二者仍配对
  }
}
