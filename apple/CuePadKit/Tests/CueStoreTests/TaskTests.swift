import CueStore
import CueTestSupport
import Foundation
import Testing

/// 灵感与任务是同一种记录（Card）：差别只是"要做"（`todoAt`）。任务三态、可有步骤（任务最多两级），也可挂灵感；
/// 只有任务能当上级；去掉"要做"或进回收站时，下级按原顺序提到它的位置；归档连同下级。
@Suite struct TaskTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  private func card(_ id: UUID) async throws -> Card { try #require(try await store.card(id)) }

  @Test func 移动_不能成环或任务超两级_换项目带着子树_取消要做与进回收站时下级上提() async throws {
    let site = try await store.createProject(name: "网站", color: "#111")
    let table = try await store.createProject(name: "圆桌", color: "#111")
    let a = try await store.createTask("a")
    let a1 = try await store.createTask("a1", under: a.id)
    let b = try await store.createTask("b")
    let b1 = try await store.createTask("b1", under: b.id)

    await #expect(throws: CueStoreError.invalidParent) { try await store.moveCard(a.id, to: .under(a1.id), after: nil) }
    await #expect(throws: CueStoreError.taskTooDeep) { try await store.moveCard(a.id, to: .under(b1.id), after: nil) }
    #expect(try await card(a.id).parentID == nil)

    // 挂到别的项目的任务下：整棵子树换到那个项目，同级按放的位置排
    let moving = try await store.createTask("换首图", in: site.id)
    let child = try await store.createCard(body: "裁图")
    try await store.moveCard(child.id, to: .under(moving.id), after: nil)
    let parent = try await store.createTask("上线", in: table.id)
    let first = try await store.createTask("备份", under: parent.id)
    let last = try await store.createTask("发布", under: parent.id)
    let change = try await store.moveCard(moving.id, to: .under(parent.id), after: first.id)
    // 任务成了步骤，下级跟着换项目
    #expect(try await store.children(of: parent.id).map(\.id) == [first.id, moving.id, last.id])
    #expect(try await card(child.id).parentID == moving.id)
    #expect(try await card(child.id).projectID == table.id)
    #expect(try await card(moving.id).projectID == table.id)
    try await store.undo(change)
    #expect(try await card(moving.id).parentID == nil)

    // 取消要做、进回收站：下级按原顺序提到它的位置
    let release = try await store.createProject(name: "发布", color: "#111")
    let after = try await store.createTask("后一条", in: release.id)
    let middle = try await store.createTask("备份", in: release.id)
    let before = try await store.createTask("前一条", in: release.id)
    let sub1 = try await store.createTask("导出", under: middle.id)
    let sub2 = try await store.createTask("上传", under: middle.id)
    func tasks() async throws -> [UUID] { try await store.tasks(.todo).flatMap(\.tasks).filter { $0.projectID == release.id }.map(\.id) }
    try await store.setTodo(middle.id, false)
    #expect(try await tasks() == [before.id, sub1.id, sub2.id, after.id])
    let lifted = try await [card(sub1.id), card(sub2.id)]
    #expect(lifted.allSatisfy { $0.parentID == nil && $0.projectID == release.id } && lifted[0].sortKey < lifted[1].sortKey)
    try await store.setTodo(middle.id, true)
    try await store.moveCard(sub1.id, to: .under(middle.id), after: nil)
    try await store.trashCard(middle.id)
    #expect(try await tasks() == [before.id, sub1.id, sub2.id, after.id])
  }

  @Test func 归档不占列表仍可搜到_连同下级一起取回_一键全部归档只动已完成的顶层任务() async throws {
    let project = try await store.createProject(name: "圆桌", color: "#111")
    let idea = try await store.createCard(in: project.id, body: "接口约定")
    try await store.archive(idea.id)
    #expect(try await store.cards(in: project.id).isEmpty)
    #expect(try await store.search("接口约定").cards.map(\.id) == [idea.id])
    try await store.unarchive(idea.id)
    #expect(try await store.cards(in: project.id).map(\.id) == [idea.id])

    let done = try await store.createTask("上线")
    let sub = try await store.createTask("备份", under: done.id)
    let prompt = try await store.createCard(body: "日志")
    try await store.moveCard(prompt.id, to: .under(done.id), after: nil)
    try await store.setStatus(done.id, .done)
    let open = try await store.createTask("还在做")
    let doneStep = try await store.createTask("已复现", under: open.id)
    try await store.setStatus(doneStep.id, .done)  // 没做完的任务下已完成的步骤算在上级的进度里，不单独归档

    #expect(try await store.archiveCompletedTasks() == 1)
    for id in [done.id, sub.id, prompt.id] { #expect(try await card(id).archivedAt != nil) }
    for id in [open.id, doneStep.id] { #expect(try await card(id).archivedAt == nil) }
    try await store.unarchive(done.id)
    for id in [done.id, sub.id, prompt.id] { #expect(try await card(id).archivedAt == nil) }
  }

}
