import CueStore
import CueTestSupport
import Foundation
import Testing

/// 给用户看的任务数与完成数只按顶层任务计（子任务的进度在上级那一行，见 `subtaskProgress`）：
/// 顶层是显示在顶层的任务——没有上级、上级不在库里，或自己没完成而上级已完成（看板上它就在顶层）。
@Suite struct TaskCountTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  @Test func 各项目按顶层任务计数_子任务不算() async throws {
    let project = try await store.createProject(name: "圆桌", color: "#111")
    let release = try await store.createTask("上线", in: project.id)
    let backup = try await store.createTask("备份", under: release.id)
    _ = try await store.createTask("发布", under: release.id)
    try await store.setStatus(backup.id, .inProgress)
    let fix = try await store.createTask("修重连", in: project.id)
    try await store.setStatus(fix.id, .done)
    _ = try await store.createTask("散的", in: nil)

    let counts = try await store.taskCounts()

    #expect(counts[project.id] == TaskCounts(inProgress: 0, todo: 1, done: 1))
    #expect(counts[nil] == TaskCounts(inProgress: 0, todo: 1, done: 0))
  }

  @Test func 上级已完成而自己重新打开的子任务_算顶层() async throws {
    let release = try await store.createTask("上线", in: nil)
    let backup = try await store.createTask("备份", under: release.id)
    try await store.setStatus(release.id, .done)
    try await store.setStatus(backup.id, .todo)

    #expect(try await store.taskCounts()[nil] == TaskCounts(inProgress: 0, todo: 1, done: 1))
  }
}
