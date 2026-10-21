import CueStore
import Foundation
import Testing

@Suite struct SearchTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  private func setModified(_ card: Card, _ seconds: Int) throws {
    try RawDB(fixture.url).exec("UPDATE cards SET modifiedAt = \(seconds * 1000) WHERE id = '\(card.id.uuidString.lowercased())'")
  }

  @Test func findsProjectsAndCardsIncludingShortCJKTerms() async throws {
    let flow = try await store.createProject(name: "Flow 启动", color: "#111")
    let card = try await store.createCard(in: flow.id, body: "优化 flow 启动速度")

    let byName = try await store.search("flow")
    #expect(byName.projects.map(\.id) == [flow.id])
    #expect(byName.cards.map(\.id) == [card.id])

    let cjk = try await store.search("优化")  // 两个字，短于三字符索引
    #expect(cjk.cards.map(\.id) == [card.id])

    _ = try await store.createCard(body: "1000 items")
    let percent = try await store.createCard(body: "达成 100% 完成")
    let literal = try await store.search("100%")  // 通配符按字面匹配，不命中 "1000 items"
    #expect(literal.cards.map(\.id) == [percent.id])
  }

  /// Cue 的 recall：命中词多的旧卡片排在只命中一个词的大批新卡片前面，不被按新旧先截掉。
  @Test func cueRecallRanksTheOlderCardHittingMoreWordsFirst() async throws {
    let old = try await store.createCard(body: "ALPHA BETA 旧的那张")
    try setModified(old, 1)
    for i in 0..<250 {
      _ = try await store.createCard(body: "ALPHA \(i)")
      _ = try await store.createCard(body: "BETA \(i)")
    }
    let cards = try await store.recallCue("ALPHA BETA GAMMA", limit: 3).cards
    #expect(cards.first?.id == old.id)
    #expect(cards.count == 3)
  }

  @Test func indexFollowsEditsAndPurges() async throws {
    let card = try await store.createCard(body: "alpha")
    try await store.updateCard(card.id) { $0.body = "bravo" }
    #expect(try await store.search("alpha").cards.isEmpty)
    #expect(try await store.search("bravo").cards.map(\.id) == [card.id])

    try await store.purgeCard(card.id)
    #expect(try await store.search("bravo").cards.isEmpty)
  }

  @Test func searchScopeSeparatesLiveFromTrash() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    let inProject = try await store.createCard(in: p.id, body: "needle in project")
    let alone = try await store.createCard(body: "needle alone")
    try await store.trashCard(alone.id)
    try await store.trashProject(p.id)

    #expect(try await store.search("needle").cards.isEmpty)
    let trash = try await store.search(SearchQuery(text: "needle", inTrash: true))
    #expect(Set(trash.cards.map(\.id)) == [inProject.id, alone.id])
  }

  @Test func projectFilterAppliesBeforeThePageLimit() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    let q = try await store.createProject(name: "Q", color: "#222")
    for index in 0..<25 { _ = try await store.createCard(in: q.id, body: "needle \(index)") }
    let wanted = try await store.createCard(in: p.id, body: "needle wanted")
    try setModified(wanted, 0)  // 排在所有卡片之后

    let hit = try await store.search(SearchQuery(text: "needle", projects: [p.id]), limit: 20)

    #expect(hit.cards.map(\.id) == [wanted.id] && hit.totalCards == 1)
  }

  @Test func pagesCoverEveryMatchOnceInModifiedOrderWithStableTotal() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    var made: [Card] = []
    for index in 0..<5 {
      let card = try await store.createCard(in: p.id, body: "note \(index)")
      try setModified(card, 100 + index)
      made.append(card)
    }

    var seen: [UUID] = []
    for offset in stride(from: 0, to: 6, by: 2) {
      let page = try await store.search(SearchQuery(text: "note"), limit: 2, offset: offset)
      #expect(page.totalCards == 5)
      seen += page.cards.map(\.id)
    }
    #expect(seen == made.reversed().map(\.id))
  }
}
