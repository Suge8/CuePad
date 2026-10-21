import CueStore
import Foundation
import Testing

/// 搜索的匹配与分页（按名字、短的中文词与多个词的过滤见 CueCLITests 的 `searchMatchesAllTermsAndAppliesFilters`）。
@Suite struct SearchTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  private func setModified(_ card: Card, _ seconds: Int) throws {
    try RawDB(fixture.url).exec("UPDATE cards SET modifiedAt = \(seconds * 1000) WHERE id = '\(card.id.uuidString.lowercased())'")
  }

  @Test func indexFollowsEditsPurgesAndTrashAndMatchesWildcardsLiterally() async throws {
    let card = try await store.createCard(body: "alpha")
    try await store.updateCard(card.id) { $0.body = "bravo" }
    #expect(try await store.search("alpha").cards.isEmpty)
    #expect(try await store.search("bravo").cards.map(\.id) == [card.id])
    try await store.purgeCard(card.id)
    #expect(try await store.search("bravo").cards.isEmpty)

    let p = try await store.createProject(name: "P", color: "#111")
    let inProject = try await store.createCard(in: p.id, body: "needle in project")
    let alone = try await store.createCard(body: "needle alone")
    try await store.trashCard(alone.id)
    try await store.trashProject(p.id)
    #expect(try await store.search("needle").cards.isEmpty)
    #expect(Set(try await store.search(SearchQuery(text: "needle", inTrash: true)).cards.map(\.id)) == [inProject.id, alone.id])

    _ = try await store.createCard(body: "1000 items")
    let percent = try await store.createCard(body: "达成 100% 完成")
    #expect(try await store.search("100%").cards.map(\.id) == [percent.id])  // 通配符按字面匹配
  }

  @Test func projectFilterAppliesBeforeThePageLimitAndPagesCoverEveryMatchOnce() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    let q = try await store.createProject(name: "Q", color: "#222")
    for index in 0..<25 { _ = try await store.createCard(in: q.id, body: "needle \(index)") }
    let wanted = try await store.createCard(in: p.id, body: "needle wanted")
    try setModified(wanted, 0)  // 排在所有卡片之后
    let hit = try await store.search(SearchQuery(text: "needle", projects: [p.id]), limit: 20)
    #expect(hit.cards.map(\.id) == [wanted.id] && hit.totalCards == 1)

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
