import CueStore
import CueText
import Foundation
import Testing

/// 你在 Cue 页发的图片：卡片永久删除后，Cue 对话里还引用着的图片留着。
@Suite struct CueMessageImageTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  @Test func anImageStillInTheCueConversationSurvivesPurgingTheCard() async throws {
    let hash = try store.files.store(pngData())
    let card = try await store.createCard(in: nil, body: CueFormat.imageMarkup(id: hash))
    try await store.addCueMessage(.you, text: "看这张 " + CueFormat.imageMarkup(id: hash))
    try await store.purgeCard(card.id)
    #expect(store.files.fileURL(for: hash) != nil)
  }
}
