import CueStore
import Foundation
import Testing

/// 会留下"撤销"的卡片改动（删除、挪动）：回执在改动的同一个事务里读到、改动之后原样拨回，
/// 中间没有别的写入能插进来；点任务的圆圈也是读、改在一个事务里。
@Suite struct CardUndoTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  private func card(_ id: UUID) async throws -> Card { try #require(try await store.card(id)) }

  /// 项目顶层（灵感与任务共用一个手动顺序）按顺序的 id。
  private func topOrder(_ project: UUID) async throws -> [UUID] {
    let all = try await store.cards(in: project) + store.tasks(in: project, .todo, .inProgress, .done).filter { $0.parentID == nil }
    return all.sorted { ($0.sortKey, $0.id.uuidString) < ($1.sortKey, $1.id.uuidString) }.map(\.id)
  }

  @Test func 批量删除一次撤销_全部回到原处() async throws {
    let project = try await store.createProject(name: "P", color: "#111")
    let ideas = [try await store.createCard(in: project.id, body: "一"), try await store.createCard(in: project.id, body: "二"),
                 try await store.createCard(in: project.id, body: "三")]
    let kept = try await store.createCard(in: project.id, body: "留着")
    let order = try await topOrder(project.id)

    let changes = try await store.trashCards(ideas.map(\.id))
    #expect(try await store.cards(in: project.id).map(\.id) == [kept.id])
    try await store.undo(changes)

    #expect(try await topOrder(project.id) == order)
  }

  /// 删除把下级提到它的位置；拨回后下级（含归档的）按原顺序回到它下面。
  @Test func 删除拨回_下级含归档的按原顺序回到它下面() async throws {
    let task = try await store.createTask("上线")
    let note = try await store.createCard(body: "回滚方案")
    let old = try await store.createCard(body: "旧的备忘")
    for idea in [note, old] { try await store.moveCard(idea.id, to: .under(task.id), after: nil) }
    try await store.archive(old.id)
    let a = try await store.createTask("清单", under: task.id)
    let b = try await store.createTask("备份", under: task.id)

    let change = try #require(try await store.trashCard(task.id))
    #expect(try await card(a.id).parentID == nil)
    try await store.undo(change)

    let restored = try await card(task.id)
    #expect(restored.isTask && restored.deletedAt == nil)
    #expect(try await store.children(of: task.id).map(\.id) == [note.id, a.id, b.id])
    #expect(try await card(old.id).parentID == task.id)
  }

  @Test func 挪动拨回_回到原来的位置_前一个同级是任务也对() async throws {
    let project = try await store.createProject(name: "圆桌", color: "#111")
    let target = try await store.createTask("目标", in: project.id)
    let idea = try await store.createCard(in: project.id, body: "想法")
    let task = try await store.createTask("相邻的任务", in: project.id)  // 新建的排在最前
    _ = try await store.createCard(in: project.id, body: "尾巴")
    try await store.moveCard(idea.id, to: .top(project: project.id), after: task.id)  // 任务 → 想法 → …
    let order = try await topOrder(project.id)
    #expect(order.firstIndex(of: task.id)! + 1 == order.firstIndex(of: idea.id)!)

    let change = try await store.moveCard(idea.id, to: .under(target.id), after: nil)
    #expect(try await card(idea.id).parentID == target.id)
    try await store.undo(change)

    #expect(try await card(idea.id).parentID == nil)
    #expect(try await topOrder(project.id) == order)
  }

}
