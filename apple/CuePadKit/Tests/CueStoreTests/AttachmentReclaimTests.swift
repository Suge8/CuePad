import CueStore
import Foundation
import Testing

/// 永久删除卡片时，回收不再被任何卡片正文（含回收站里的卡）、发送记录快照或 Cue 对话引用的附件：记录与文件一起删；
/// 刚粘贴、还没存进正文的图片不碰。
@Suite struct AttachmentReclaimTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }
  var attachmentsDirectory: URL { fixture.directory.appending(path: "Attachments", directoryHint: .isDirectory) }

  private func ref(_ hash: String) -> String { "text ![](cuepad://img/\(hash)) more" }

  private func exists(_ hash: String) throws -> Bool {
    let row = try RawDB(fixture.url).rows("SELECT 1 FROM attachments WHERE hash = '\(hash)'")
    let file = FileManager.default.fileExists(atPath: attachmentsDirectory.appending(path: hash).path)
    #expect(row.isEmpty || file, "附件记录必须有文件")
    return file
  }

  @Test func purgingACardDropsOnlyImagesNothingElseStillUses() async throws {
    let images = try (0..<6).map { try store.files.store(pngData(width: 8, height: 8, shade: CGFloat($0) / 10)) }
    let (shared, inTrash, sent, inCue, solo, pending) = (images[0], images[1], images[2], images[3], images[4], images[5])
    let doomed = try await store.createCard(body: [shared, inTrash, sent, inCue, solo].map(ref).joined())
    _ = try await store.createCard(body: ref(shared))
    let trashed = try await store.createCard(body: ref(inTrash))
    try await store.trashCard(trashed.id)
    try await store.recordSend(ref(sent), to: SendTarget(kind: .piSession, name: "s", ref: "s1"), card: doomed.id)  // 一键重发还要用它
    try await store.addCueMessage(.you, text: ref(inCue))

    try await store.purgeCard(doomed.id)

    for kept in [shared, inTrash, sent, inCue, pending] { #expect(try exists(kept)) }
    #expect(try !exists(solo))
    try await store.purgeCard(trashed.id)
    #expect(try !exists(inTrash))
  }
}
