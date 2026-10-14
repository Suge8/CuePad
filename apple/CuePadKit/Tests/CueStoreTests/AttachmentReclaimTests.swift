import CueStore
import Foundation
import Testing

/// 永久删除卡片时，回收不再被任何卡片正文（含回收站里的卡）、发送记录快照或 Cue 对话引用的附件：记录与文件一起删。
@Suite struct AttachmentReclaimTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }
  var attachmentsDirectory: URL { fixture.directory.appending(path: "Attachments", directoryHint: .isDirectory) }

  private func image(_ shade: CGFloat) async throws -> String {
    try store.files.store(pngData(width: 8, height: 8, shade: shade))
  }

  private func ref(_ hash: String) -> String { "text ![](cuepad://img/\(hash)) more" }

  private func exists(_ hash: String) throws -> Bool {
    let row = try RawDB(fixture.url).rows("SELECT 1 FROM attachments WHERE hash = '\(hash)'")
    let file = FileManager.default.fileExists(atPath: attachmentsDirectory.appending(path: hash).path)
    #expect(row.isEmpty || file, "附件记录必须有文件")
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

  @Test func imageNotYetInsertedIntoAnyCardIsNotTouchedByUnrelatedPurges() async throws {
    let pending = try await image(0.1)  // 刚粘贴、正文还没保存
    let card = try await store.createCard(in: nil, body: "plain")
    try await store.purgeCard(card.id)
    #expect(try exists(pending))
  }

  @Test func imageReferencedBySendRecordSnapshotSurvivesPurgingItsCard() async throws {
    let sent = try await image(0.1)
    let unsent = try await image(0.2)
    let card = try await store.createCard(in: nil, body: ref(sent) + ref(unsent))
    try await store.recordSend(
      ref(sent), to: SendTarget(kind: .piSession, name: "s", ref: "s1"), card: card.id)  // 快照只含 sent

    try await store.purgeCard(card.id)

    #expect(try exists(sent))  // 一键重发还要用它
    #expect(try !exists(unsent))
  }

  /// 你在 Cue 页发的图片：卡片永久删除后，Cue 对话里还引用着就留着。
  @Test func imageStillInTheCueConversationSurvivesPurgingItsCard() async throws {
    let hash = try await image(0.1)
    let card = try await store.createCard(in: nil, body: ref(hash))
    try await store.addCueMessage(.you, text: ref(hash))
    try await store.purgeCard(card.id)
    #expect(try exists(hash))
  }
}
