import CueStore
import CueTestSupport
import Foundation
import Testing

/// 任务层级：任务 → 子任务 → 子任务，最多三级。结构只经 `createTask(_:under:)` 与 `moveCard` 改，写入时在 Store 校验；
/// 下级跟着上级的项目；同级按手动顺序；完成上级时没完成的子任务一起完成。（下级上提见 `CardTaskTests`。）
@Suite struct TaskTreeTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  private func children(of parent: UUID) async throws -> [UUID] {
    try await store.tasks(.todo, .inProgress, .done).flatMap(\.tasks).filter { $0.parentID == parent }.map(\.id)
  }

  @Test func 子任务挂在父任务下并跟随父任务的项目_最多三级() async throws {
    let project = try await store.createProject(name: "圆桌", color: "#111")
    let top = try await store.createTask("修重连", in: project.id)
    let second = try await store.createTask("改排序", under: top.id)
    let third = try await store.createTask("补用例", under: second.id)

    #expect(second.parentID == top.id && second.projectID == project.id)
    #expect(third.parentID == second.id && third.projectID == project.id)
    await #expect(throws: CueStoreError.taskTooDeep) { try await store.createTask("第四级", under: third.id) }
  }

  @Test func 移动_不能挂到自己或自己的子任务下_整棵子树超过三级时拒绝() async throws {
    let a = try await store.createTask("a", in: nil)
    let a1 = try await store.createTask("a1", under: a.id)
    let a2 = try await store.createTask("a2", under: a1.id)
    let b = try await store.createTask("b", in: nil)
    let b1 = try await store.createTask("b1", under: b.id)

    await #expect(throws: CueStoreError.invalidParent) { try await store.moveCard(a.id, to: .under(a.id), after: nil) }
    await #expect(throws: CueStoreError.invalidParent) { try await store.moveCard(a.id, to: .under(a2.id), after: nil) }
    // a 带着两级子任务，挂到 b1 下就是五级
    await #expect(throws: CueStoreError.taskTooDeep) { try await store.moveCard(a.id, to: .under(b1.id), after: nil) }
    #expect(try await store.card(a.id)?.parentID == nil)

    // 挂到顶层任务 b 下：a 第二级、a1 第三级……a2 会到第四级，同样拒绝
    await #expect(throws: CueStoreError.taskTooDeep) { try await store.moveCard(a.id, to: .under(b.id), after: nil) }
    try await store.moveCard(a1.id, to: .under(b.id), after: b1.id)
    #expect(try await children(of: b.id) == [b1.id, a1.id])
    #expect(try await store.card(a2.id)?.parentID == a1.id)
  }

  @Test func 挂到别的项目的任务下_整棵子树换到那个项目_同级按放的位置排() async throws {
    let site = try await store.createProject(name: "网站", color: "#111")
    let table = try await store.createProject(name: "圆桌", color: "#111")
    let moving = try await store.createTask("换首图", in: site.id)
    let child = try await store.createTask("裁图", under: moving.id)
    let parent = try await store.createTask("上线", in: table.id)
    let first = try await store.createTask("备份", under: parent.id)
    let last = try await store.createTask("发布", under: parent.id)

    try await store.moveCard(moving.id, to: .under(parent.id), after: first.id)

    #expect(try await children(of: parent.id) == [first.id, moving.id, last.id])
    #expect(try await store.card(moving.id)?.projectID == table.id)
    #expect(try await store.card(child.id)?.projectID == table.id)

    // 移回顶层，放在另一个项目的某条之后
    let anchor = try await store.createTask("锚", in: site.id)
    try await store.moveCard(moving.id, to: .top(project: site.id), after: anchor.id)
    let moved = try #require(try await store.card(moving.id))
    #expect(moved.parentID == nil && moved.projectID == site.id)
    #expect(try await store.card(child.id)?.projectID == site.id)
  }

  @Test func 子任务挪到别的项目顶层_离开上级_它的子任务跟着过去() async throws {
    let site = try await store.createProject(name: "网站", color: "#111")
    let table = try await store.createProject(name: "圆桌", color: "#111")
    let top = try await store.createTask("上线", in: site.id)
    let middle = try await store.createTask("备份", under: top.id)
    let leaf = try await store.createTask("导出", under: middle.id)

    try await store.moveCard(middle.id, to: .top(project: table.id), after: nil)

    let moved = try #require(try await store.card(middle.id))
    #expect(moved.parentID == nil && moved.projectID == table.id)
    #expect(try await store.card(leaf.id)?.projectID == table.id)
    #expect(try await store.card(leaf.id)?.parentID == middle.id)
  }

  @Test func 完成父任务_没完成的子任务一起完成_重新打开父任务不动子任务() async throws {
    let top = try await store.createTask("上线", in: nil)
    let open = try await store.createTask("备份", under: top.id)
    let deep = try await store.createTask("导出", under: open.id)
    let finished = try await store.createTask("写说明", under: top.id)
    try await store.setStatus(finished.id, .done)
    let finishedAt = try #require(try await store.card(finished.id)?.completedAt)

    try await store.setStatus(top.id, .done)

    for id in [top.id, open.id, deep.id] { #expect(try await store.card(id)?.status == .done) }
    #expect(try await store.card(finished.id)?.completedAt == finishedAt)

    try await store.setStatus(top.id, .todo)
    #expect(try await store.card(top.id)?.status == .todo)
    #expect(try await store.card(open.id)?.status == .done)
  }

  @Test func 父任务的子任务完成数与总数_只算直接子任务() async throws {
    let top = try await store.createTask("上线", in: nil)
    let a = try await store.createTask("备份", under: top.id)
    _ = try await store.createTask("发布", under: top.id)
    _ = try await store.createTask("导出", under: a.id)
    try await store.setStatus(a.id, .done)

    let marks = try await store.childMarks()
    #expect(TaskProgress.subtasks(in: marks[top.id]) == TaskProgress(done: 1, total: 2))
    #expect(TaskProgress.subtasks(in: marks[a.id]) == TaskProgress(done: 1, total: 1))  // 完成 a 时它的子任务一起完成
  }
}
