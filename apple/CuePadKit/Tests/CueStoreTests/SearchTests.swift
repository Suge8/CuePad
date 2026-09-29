import CueStore
import Foundation
import Testing

@Suite struct SearchTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  @Test func findsProjectsCardsAndCardsByTagIncludingShortCJKTerms() async throws {
    let flow = try await store.createProject(name: "Flow 启动", color: "#111")
    let card = try await store.createCard(in: flow.id, body: "优化 flow 启动速度")
    let tagged = try await store.createCard(in: nil, body: "无关正文")
    _ = try await store.addTag("重构", to: tagged.id)

    let byName = try await store.search("flow")
    #expect(byName.projects.map(\.id) == [flow.id])
    #expect(byName.cards.map(\.id) == [card.id])

    let cjk = try await store.search("优化")  // 两个字，短于三字符索引
    #expect(cjk.cards.map(\.id) == [card.id])

    let byTag = try await store.search("重构")
    #expect(byTag.cards.map(\.id) == [tagged.id])

    _ = try await store.createCard(in: nil, body: "1000 items")
    let percent = try await store.createCard(in: nil, body: "达成 100% 完成")
    let literal = try await store.search("100%")  // 通配符按字面匹配，不命中 "1000 items"
    #expect(literal.cards.map(\.id) == [percent.id])
  }

  @Test func indexFollowsEditsAndPurges() async throws {
    let card = try await store.createCard(in: nil, body: "alpha")
    try await store.updateCard(card.id) { $0.body = "bravo" }
    #expect(try await store.search("alpha").cards.isEmpty)
    #expect(try await store.search("bravo").cards.map(\.id) == [card.id])

    try await store.purgeCard(card.id)
    #expect(try await store.search("bravo").cards.isEmpty)
  }

  @Test func searchScopeSeparatesLiveFromTrash() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    let inProject = try await store.createCard(in: p.id, body: "needle in project")
    let alone = try await store.createCard(in: nil, body: "needle alone")
    try await store.trashCard(alone.id)
    try await store.trashProject(p.id)

    #expect(try await store.search("needle").cards.isEmpty)
    let trash = try await store.search(SearchQuery(text: "needle", inTrash: true))
    #expect(Set(trash.cards.map(\.id)) == [inProject.id, alone.id])
  }
}
