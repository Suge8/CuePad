import CueStore
import Foundation
import Testing

/// 不变量：卡片（灵感与任务）的 projectID 只能指向存在且未在回收站的项目，或 nil。
/// 由 Store 在写事务里校验，失效时报错而不是悄悄改成未分类（回落策略属于界面）。
@Suite struct ProjectReferenceTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }
  var raw: RawDB { RawDB(fixture.url) }

  /// 回收站里的项目、已永久删除的项目、从未存在的项目。
  private func deadProjects() async throws -> [UUID] {
    let trashed = try await store.createProject(name: "trashed", color: "#111")
    let purged = try await store.createProject(name: "purged", color: "#222")
    try await store.trashProject(trashed.id)
    try await store.trashProject(purged.id)
    try await store.purgeProject(purged.id)
    return [trashed.id, purged.id, UUID()]
  }

  @Test func createCardRejectsDeadProjectsAndWritesNothing() async throws {
    for project in try await deadProjects() {
      await #expect(throws: CueStoreError.invalidProject) { try await store.createCard(in: project, body: "x") }
    }
    #expect(try raw.count("cards") == 0)
  }

  @Test func moveCardRejectsDeadProjectsAndLeavesTheCardWhereItWas() async throws {
    let home = try await store.createProject(name: "home", color: "#111")
    let card = try await store.createCard(in: home.id, body: "x")
    let before = try await store.card(card.id)
    for project in try await deadProjects() {
      await #expect(throws: CueStoreError.invalidProject) {
        try await store.moveCard(card.id, to: .top(project: project), after: nil)
      }
    }
    #expect(try await store.card(card.id) == before)
  }

  @Test func createTaskRejectsDeadProjectsAndWritesNothing() async throws {
    for project in try await deadProjects() {
      await #expect(throws: CueStoreError.invalidProject) { try await store.createTask("t", in: project) }
    }
    #expect(try raw.count("cards") == 0)
  }

  @Test func liveProjectsAndUnfiledStillWork() async throws {
    let live = try await store.createProject(name: "live", color: "#111")
    let card = try await store.createCard(in: live.id, body: "a")
    _ = try await store.createCard(in: nil, body: "b")
    try await store.moveCard(card.id, to: .top(project: nil), after: nil)
    try await store.moveCard(card.id, to: .top(project: live.id), after: nil)
    _ = try await store.createTask("t", in: live.id)
    _ = try await store.createTask("u", in: nil)
    #expect(try raw.count("cards") == 4)
  }
}
