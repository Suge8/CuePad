import CueStore
import CueTestSupport
import Foundation
import Testing

/// 任务三态：待办、进行中、完成。按状态查询时跨项目分组（项目顺序同 `projects()`，未归档的在最后）。
@Suite struct TaskStatusTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  @Test func statusMovesBetweenTheThreeStatesAndKeepsTheTimes() async throws {
    let task = try await store.createTask("修登录", in: nil)
    #expect(task.status == .todo && task.startedAt == nil && task.completedAt == nil)

    try await store.setStatus(task.id, .inProgress)
    let started = try #require(try await store.card(task.id))
    #expect(started.status == .inProgress && started.startedAt != nil && started.completedAt == nil)

    try await store.setStatus(task.id, .done)
    let done = try #require(try await store.card(task.id))
    #expect(done.status == .done && done.completedAt != nil && done.startedAt == started.startedAt)

    try await store.setStatus(task.id, .todo)
    let reopened = try #require(try await store.card(task.id))
    #expect(reopened.status == .todo && reopened.startedAt == nil && reopened.completedAt == nil)
  }

  @Test func tasksByStatusAreGroupedByProjectInProjectOrder() async throws {
    let older = try await store.createProject(name: "旧", color: "#111")
    let pinned = try await store.createProject(name: "置顶", color: "#111")
    try await store.updateProject(pinned.id) { $0.isPinned = true }
    let a = try await store.createTask("a", in: older.id)
    let b = try await store.createTask("b", in: pinned.id)
    let c = try await store.createTask("c", in: nil)
    let d = try await store.createTask("d", in: pinned.id)
    try await store.setStatus(d.id, .done)

    let todo = try await store.tasks(.todo)
    #expect(todo.map(\.projectID) == [pinned.id, older.id, nil])
    #expect(todo.map { $0.tasks.map(\.id) } == [[b.id], [a.id], [c.id]])
    #expect(try await store.tasks(.done).map { $0.tasks.map(\.id) } == [[d.id]])
    #expect(try await store.tasks(.inProgress).isEmpty)
  }
}
