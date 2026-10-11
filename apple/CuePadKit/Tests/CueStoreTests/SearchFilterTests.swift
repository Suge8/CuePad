import CueStore
import Foundation
import Testing

@Suite struct SearchFilterTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  private func setModified(_ card: Card, _ seconds: Int) throws {
    try RawDB(fixture.url).exec("UPDATE cards SET modifiedAt = \(seconds * 1000) WHERE id = '\(card.id.uuidString.lowercased())'")
  }

  private func bodies(_ results: SearchResults) -> [String] { results.cards.map(\.body) }

  /// P: c1（含图）c2；Q: c3（发给 Pi 会话 s1）c5（很久以前修改）；未分类: c4（发给 Ghostty）。
  private struct World {
    let p: Project, q: Project
    let c1: Card, c2: Card, c3: Card, c4: Card, c5: Card
  }

  private func world() async throws -> World {
    let p = try await store.createProject(name: "P", color: "#111")
    let q = try await store.createProject(name: "Q", color: "#222")
    let hash = String(repeating: "a", count: 64)
    let c1 = try await store.createCard(in: p.id, body: "alpha one ![](cuepad://img/\(hash))")
    let c2 = try await store.createCard(in: p.id, body: "alpha two")
    let c3 = try await store.createCard(in: q.id, body: "alpha three")
    let c4 = try await store.createCard(in: nil, body: "gamma four")
    let c5 = try await store.createCard(in: q.id, body: "alpha five")
    try await store.recordSend("x", to: SendTarget(kind: .piSession, name: "s1-title", ref: "s1"), card: c3.id)
    try await store.recordSend("y", to: SendTarget(kind: .piSession, name: "review", ref: "s2"), card: c4.id)
    for (index, card) in [c1, c2, c3, c4].enumerated() { try setModified(card, 1_000 + index * 100) }
    try setModified(c5, 10)
    return World(p: p, q: q, c1: c1, c2: c2, c3: c3, c4: c4, c5: c5)
  }

  // MARK: 筛选

  @Test func projectFilterAppliesBeforeThePageLimit() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    let q = try await store.createProject(name: "Q", color: "#222")
    for index in 0..<25 { _ = try await store.createCard(in: q.id, body: "needle \(index)") }
    let wanted = try await store.createCard(in: p.id, body: "needle wanted")
    try RawDB(fixture.url).exec("UPDATE cards SET modifiedAt = 1 WHERE id = '\(wanted.id.uuidString.lowercased())'")  // 排在所有卡片之后

    let hit = try await store.search(SearchQuery(text: "needle", projects: [p.id]), limit: 20)

    #expect(hit.cards.map(\.id) == [wanted.id] && hit.totalCards == 1)
  }

  @Test func projectFilterAcceptsSeveralProjectsAndUnfiled() async throws {
    let w = try await world()
    #expect(Set(try await store.search(SearchQuery(projects: [w.p.id])).cards.map(\.id)) == [w.c1.id, w.c2.id])
    #expect(try await store.search(SearchQuery(projects: [nil])).cards.map(\.id) == [w.c4.id])
    let union = try await store.search(SearchQuery(projects: [w.q.id, nil]))
    #expect(Set(union.cards.map(\.id)) == [w.c3.id, w.c5.id, w.c4.id])
    #expect(try await store.search(SearchQuery(projects: [])).cards.isEmpty)
  }

  @Test func imageFilterSeparatesCardsWithAndWithoutImages() async throws {
    let w = try await world()
    let with = try await store.search(SearchQuery(text: "alpha", hasImages: true))
    #expect(with.cards.map(\.id) == [w.c1.id])
    let without = try await store.search(SearchQuery(text: "alpha", hasImages: false))
    #expect(Set(without.cards.map(\.id)) == [w.c2.id, w.c3.id, w.c5.id])
  }

  @Test func sendTargetFilterMatchesKindAndName() async throws {
    let w = try await world()
    #expect(Set(try await store.search(SearchQuery(sent: .sent(kind: .known(.piSession)))).cards.map(\.id)) == [w.c3.id, w.c4.id])
    #expect(try await store.search(SearchQuery(sent: .sent(name: "review"))).cards.map(\.id) == [w.c4.id])
    #expect(try await store.search(SearchQuery(sent: .sent(kind: .known(.mac), name: "s1-title"))).cards.isEmpty)
    let anySend = try await store.search(SearchQuery(sent: .sent()))
    #expect(Set(anySend.cards.map(\.id)) == [w.c3.id, w.c4.id])
  }

  @Test func neverSentSelectsCardsWithoutAnySendRecord() async throws {
    let w = try await world()
    #expect(Set(try await store.search(SearchQuery(sent: .never)).cards.map(\.id)) == [w.c1.id, w.c2.id, w.c5.id])
    #expect(Set(try await store.search(SearchQuery(text: "alpha", sent: .never)).cards.map(\.id)) == [w.c1.id, w.c2.id, w.c5.id])
    #expect(try await store.search(SearchQuery(projects: [w.p.id], hasImages: true, sent: .never)).cards.map(\.id) == [w.c1.id])

    try await store.recordSend("late", to: SendTarget(kind: .piSession, name: "late", ref: "s3"), card: w.c1.id)
    #expect(Set(try await store.search(SearchQuery(sent: .never)).cards.map(\.id)) == [w.c2.id, w.c5.id])
    let all = try await store.search(SearchQuery(sent: .any))  // 不限：已发送与未发送都在
    #expect(all.totalCards == 5)
  }

  @Test func neverSentCountsAsACardFilterSoProjectsAreNotListed() async throws {
    _ = try await world()
    #expect(try await store.search(SearchQuery(text: "P", sent: .never)).projects.isEmpty)
  }

  @Test func modifiedRangeFilterIsInclusive() async throws {
    let w = try await world()
    let range = Date(timeIntervalSince1970: 1_000)...Date(timeIntervalSince1970: 1_100)
    #expect(Set(try await store.search(SearchQuery(modifiedIn: range)).cards.map(\.id)) == [w.c1.id, w.c2.id])
  }

  @Test func filtersCombineAndWorkWithoutKeyword() async throws {
    let w = try await world()
    let query = SearchQuery(projects: [w.q.id], sent: .sent(kind: .known(.piSession)))
    #expect(try await store.search(query).cards.map(\.id) == [w.c3.id])
    #expect(try await store.search(SearchQuery(text: "gamma", projects: [w.q.id])).cards.isEmpty)
  }

  @Test func filtersApplyInsideTheTrashScopeToo() async throws {
    let w = try await world()
    try await store.trashCard(w.c3.id)
    let live = SearchQuery(sent: .sent(kind: .known(.piSession)))
    #expect(try await store.search(live).cards.map(\.id) == [w.c4.id])
    let trash = SearchQuery(sent: .sent(kind: .known(.piSession)), inTrash: true)
    #expect(try await store.search(trash).cards.map(\.id) == [w.c3.id])
  }

  @Test func projectNamesMatchOnlyWhenNoCardFilterIsActive() async throws {
    let w = try await world()
    #expect(try await store.search("P").projects.map(\.id).contains(w.p.id))
    #expect(try await store.search(SearchQuery(text: "P", hasImages: true)).projects.isEmpty)
  }

  // MARK: 分页与总数

  @Test func pagesCoverEveryMatchOnceInModifiedOrderWithStableTotal() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    var made: [Card] = []
    for index in 0..<5 {
      let card = try await store.createCard(in: p.id, body: "note \(index)")
      try setModified(card, 100 + index)
      made.append(card)
    }
    let newestFirst = made.reversed().map(\.id)

    var seen: [UUID] = []
    for offset in stride(from: 0, to: 6, by: 2) {
      let page = try await store.search(SearchQuery(text: "note"), limit: 2, offset: offset)
      #expect(page.totalCards == 5)
      seen += page.cards.map(\.id)
    }
    #expect(seen == newestFirst)
    #expect(try await store.search(SearchQuery(text: "note"), limit: 2, offset: 10).cards.isEmpty)
  }

  @Test func totalCountsAllMatchesNotJustThePage() async throws {
    for index in 0..<30 { _ = try await store.createCard(in: nil, body: "bulk \(index)") }
    let page = try await store.search(SearchQuery(text: "bulk"), limit: 10)
    #expect(page.cards.count == 10 && page.totalCards == 30)
  }

  // MARK: 按项目汇总

  @Test func projectSummariesCountVisibleIdeas() async throws {
    let a = try await store.createProject(name: "A", color: "#111")
    let b = try await store.createProject(name: "B", color: "#222")
    let gone = try await store.createProject(name: "gone", color: "#333")
    _ = try await store.createCard(in: a.id, body: "a1")
    _ = try await store.createCard(in: a.id, body: "a2")
    let a3 = try await store.createCard(in: a.id, body: "a3 trashed")
    _ = try await store.createCard(in: nil, body: "i")
    _ = try await store.createCard(in: gone.id, body: "hidden with project")
    try await store.trashCard(a3.id)  // 回收站里的卡不计入
    try await store.trashProject(gone.id)

    let summaries = try await store.projectSummaries()

    #expect(summaries.map(\.projectID) == (try await store.projects().map(\.id)) + [nil])  // 项目的顺序，未分类最后
    let by = Dictionary(uniqueKeysWithValues: summaries.map { ($0.projectID, $0) })
    #expect([a.id, b.id, nil].map { by[$0]?.cardCount } == [2, 0, 1])
  }

  @Test func projectSummariesWakeObserversOnCardChanges() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    var values = store.observe([.cards, .projects]) { try $0.projectSummaries().map(\.cardCount) }.makeAsyncIterator()
    #expect(try await values.next() == [0, 0])

    _ = try await store.createCard(in: p.id, body: "x")
    #expect(try await values.next() == [1, 0])
  }
}
