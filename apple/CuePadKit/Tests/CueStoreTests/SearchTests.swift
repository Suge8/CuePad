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

  // MARK: 多个关键词（空白分隔，全部命中；每个词仍是子串）

  @Test func allTermsMustMatchInAnyOrderAndWhitespace() async throws {
    let both = try await store.createCard(in: nil, body: "alpha and beta")
    _ = try await store.createCard(in: nil, body: "alpha and gamma")
    _ = try await store.createCard(in: nil, body: "beta only")

    #expect(try await store.search("alpha beta").cards.map(\.id) == [both.id])
    #expect(try await store.search("beta alpha").cards.map(\.id) == [both.id])
    #expect(try await store.search("  alpha \t beta\n").cards.map(\.id) == [both.id])
    #expect(try await store.search("alpha\u{3000}beta").cards.map(\.id) == [both.id])  // 全角空格
    #expect(try await store.search("alpha beta delta").cards.isEmpty)
    #expect(try await store.search("alp et").cards.map(\.id) == [both.id])  // 每个词是子串
  }

  @Test func termsMayLandInBodyTagOrProjectName() async throws {
    let project = try await store.createProject(name: "Flow", color: "#111")
    let inBody = try await store.createCard(in: nil, body: "优化 启动速度")
    let tagged = try await store.createCard(in: nil, body: "alpha")
    try await store.addTag("重构", to: tagged.id)
    let inProject = try await store.createCard(in: project.id, body: "启动速度")

    #expect(try await store.search("优化 速度").cards.map(\.id) == [inBody.id])  // 两字词
    #expect(try await store.search("alpha 重构").cards.map(\.id) == [tagged.id])  // 正文 + 标签
    #expect(Set(try await store.search("flow 启动").cards.map(\.id)) == [inProject.id])  // 项目名 + 正文

    // 单个词的行为不变：项目名不让整个项目的卡片命中，项目在 projects 里单列。
    let single = try await store.search("flow")
    #expect(single.cards.isEmpty && single.projects.map(\.id) == [project.id])
  }

  @Test func projectMatchesOnlyWhenEveryTermIsInItsName() async throws {
    let both = try await store.createProject(name: "Flow 启动", color: "#111")
    _ = try await store.createProject(name: "Flow", color: "#222")
    #expect(try await store.search("flow 启动").projects.map(\.id) == [both.id])
  }

  @Test func multipleTermsCombineWithFiltersTotalsAndTrashScope() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    let hit = try await store.createCard(in: p.id, body: "needle thread")
    _ = try await store.createCard(in: nil, body: "needle thread")
    _ = try await store.createCard(in: p.id, body: "needle only")

    let filtered = try await store.search(SearchQuery(text: "needle thread", projects: [p.id]))
    #expect(filtered.cards.map(\.id) == [hit.id] && filtered.totalCards == 1)

    try await store.trashCard(hit.id)
    #expect(try await store.search(SearchQuery(text: "needle thread", projects: [p.id])).cards.isEmpty)
    #expect(try await store.search(SearchQuery(text: "needle thread", inTrash: true)).cards.map(\.id) == [hit.id])
  }
}
