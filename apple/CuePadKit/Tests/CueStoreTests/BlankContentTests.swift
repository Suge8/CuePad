import CueStore
import Foundation
import Testing

@testable import CueStore

/// 空白内容的规则（真实库里留着正文为空的灵感与名字为空的项目）：空白灵感离开编辑就不留下、不计数、不当摘要；
/// 项目名不能写成空的，旧数据里空名的项目读出来叫"未命名项目"。
@Suite struct BlankContentTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  @Test func 空白灵感离开编辑就不留下_写了字的与任务都留着() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    let blank = try await store.createCard(in: p.id)
    let spaces = try await store.createCard(in: p.id, body: " \n\n ")
    let kept = try await store.createCard(in: p.id, body: "换首图")
    let task = try await store.createTask("修乱序", in: p.id)
    let prompt = try await store.createCard(body: "", under: task.id)

    for id in [blank.id, spaces.id, kept.id, task.id, prompt.id] { try await store.dropIfBlank(id) }

    #expect(try await store.card(blank.id) == nil)
    #expect(try await store.card(spaces.id) == nil)
    #expect(try await store.card(prompt.id) == nil)
    #expect(try await store.card(kept.id) != nil)
    #expect(try await store.card(task.id) != nil)
  }

  @Test func 项目的灵感数与最近一条跳过空白灵感() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    let real = try await store.createCard(in: p.id, body: "换首图")
    try RawDB(fixture.url).exec("UPDATE cards SET modifiedAt = 1000 WHERE id = '\(real.id.uuidString)'")
    _ = try await store.createCard(in: p.id, body: "")  // 更晚，但是空白的

    let summary = try #require(try await store.projectSummaries().first { $0.projectID == p.id })
    #expect(summary.cardCount == 1)
    #expect(summary.latest?.id == real.id)
  }

  @Test func 项目名不能写成空的() async throws {
    await #expect(throws: CueStoreError.blankProjectName) { try await store.createProject(name: "  ", color: "#111") }
    let p = try await store.createProject(name: "P", color: "#111")
    await #expect(throws: CueStoreError.blankProjectName) { try await store.updateProject(p.id) { $0.name = "" } }
    #expect(try await store.project(p.id)?.name == "P")
  }

  @Test func 旧数据里空名的项目读出来叫未命名项目() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    try RawDB(fixture.url).exec("UPDATE projects SET name = '' WHERE id = '\(p.id.uuidString)'")
    #expect(try await store.project(p.id)?.name == "未命名项目")
    #expect(try await store.projects().map(\.name) == ["未命名项目"])
  }
}
