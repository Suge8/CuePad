import CueStore
import CueTestSupport
import Foundation
import Testing

/// 任务三态：待办、进行中、完成。按状态查询时跨项目分组（项目顺序同 `projects()`，未归档的在最后），另有各项目的完成/总数。
@Suite struct TaskStatusTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  @Test func statusMovesBetweenTheThreeStatesAndKeepsTheTimes() async throws {
    let task = try await store.createTask("修登录")
    #expect(task.status == .todo && task.startedAt == nil && task.completedAt == nil)

    try await store.updateTask(task.id) { $0.status = .inProgress }
    let started = try #require(try await store.task(task.id))
    #expect(started.status == .inProgress && started.startedAt != nil && started.completedAt == nil)

    try await store.updateTask(task.id) { $0.status = .done }
    let done = try #require(try await store.task(task.id))
    #expect(done.status == .done && done.completedAt != nil && done.startedAt == started.startedAt)

    try await store.updateTask(task.id) { $0.status = .todo }
    let reopened = try #require(try await store.task(task.id))
    #expect(reopened.status == .todo && reopened.startedAt == nil && reopened.completedAt == nil)
  }

  @Test func handingATaskToPiPutsItInProgress() async throws {
    let task = try await store.createTask("修登录")
    let other = try await store.createTask("只是复制")
    try await store.recordSend("修登录", to: SendTarget(kind: .piSession, name: "s", ref: "s1"), task: task.id)
    try await store.recordSend("只是复制", to: SendTarget(kind: .clipboard, name: "剪贴板"), task: other.id)

    #expect(try await store.task(task.id)?.status == .inProgress)
    #expect(try await store.task(other.id)?.status == .todo)
  }

  @Test func tasksByStatusAreGroupedByProjectInProjectOrder() async throws {
    let older = try await store.createProject(name: "旧", color: "#111")
    let pinned = try await store.createProject(name: "置顶", color: "#111")
    try await store.updateProject(pinned.id) { $0.isPinned = true }
    let a = try await store.createTask("a", in: older.id)
    let b = try await store.createTask("b", in: pinned.id)
    let c = try await store.createTask("c")
    let d = try await store.createTask("d", in: pinned.id)
    try await store.updateTask(d.id) { $0.status = .done }

    let todo = try await store.tasks(.todo)
    #expect(todo.map(\.projectID) == [pinned.id, older.id, nil])
    #expect(todo.map { $0.tasks.map(\.id) } == [[b.id], [a.id], [c.id]])
    #expect(try await store.tasks(.done).map { $0.tasks.map(\.id) } == [[d.id]])
    #expect(try await store.tasks(.inProgress).isEmpty)
  }

  @Test func eachProjectCountsDoneOutOfTotal() async throws {
    let project = try await store.createProject(name: "P", color: "#111")
    let one = try await store.createTask("1", in: project.id)
    _ = try await store.createTask("2", in: project.id)
    let three = try await store.createTask("3", in: project.id)
    _ = try await store.createTask("散的")
    try await store.updateTask(one.id) { $0.status = .done }
    try await store.updateTask(three.id) { $0.status = .inProgress }

    let progress = try await store.taskProgress()
    #expect(progress[project.id] == TaskProgress(done: 1, total: 3))
    #expect(progress[nil] == TaskProgress(done: 0, total: 1))
  }

  /// 旧库（结构版本 7）升级：已完成的任务仍是完成，其余是待办。
  @Test func upgradeKeepsCompletedTasksDone() async throws {
    let done = try await store.createTask("done")
    let open = try await store.createTask("open")
    try await store.updateTask(done.id) { $0.status = .done }
    try RawDB(fixture.url).exec("""
      ALTER TABLE tasks DROP COLUMN startedAt;
      ALTER TABLE projects ADD COLUMN sortKey TEXT NOT NULL DEFAULT 'V';
      ALTER TABLE cards ADD COLUMN numbering TEXT NOT NULL DEFAULT 'none';
      DROP INDEX cards_projectID_modifiedAt; DROP INDEX tasks_projectID_modifiedAt; DROP INDEX piSessionStates_projectID;
      ALTER TABLE piSessionStates DROP COLUMN pendingPrompt; DROP TABLE piMessages;
      PRAGMA user_version = 7;
      """)

    let reopened = try CueStore(url: fixture.url)

    #expect(try await reopened.task(done.id)?.status == .done)
    #expect(try await reopened.task(open.id)?.status == .todo)
  }
}
