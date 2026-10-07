import CueStore
import CueTestSupport
import Foundation
import Testing

/// 灵感与任务是同一种记录（Card）：差别只是"要做"（`todoAt`）。任务有三态、可有子任务与素材（挂在任务下的灵感），
/// 正文就是给 Agent 的话；交给 Agent 的会话回写到任务。只有任务能当上级；去掉"要做"或进回收站时，下级按原顺序提到它的位置。
@Suite struct CardTaskTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  private func card(_ id: UUID) async throws -> Card { try #require(try await store.card(id)) }

  @Test func 灵感点要做成为任务_三态由开始与完成时间推出_取消要做回到灵感() async throws {
    let idea = try await store.createCard(in: nil, body: "把发言轮次修好\n重连的人不再插队")
    let fresh = try await card(idea.id)
    #expect(fresh.isTask == false && fresh.status == nil)

    try await store.setTodo(idea.id, true)
    #expect(try await card(idea.id).status == .todo)
    try await store.setStatus(idea.id, .inProgress)
    #expect(try await card(idea.id).status == .inProgress)
    try await store.setStatus(idea.id, .done)
    #expect(try await card(idea.id).status == .done)

    try await store.setTodo(idea.id, false)
    let back = try await card(idea.id)
    #expect(back.isTask == false && back.status == nil && back.startedAt == nil && back.completedAt == nil)
    #expect(back.body == "把发言轮次修好\n重连的人不再插队")
  }

  @Test func 只有任务能当上级_灵感挂在任务下是素材_挂到灵感下拒绝() async throws {
    let task = try await store.createTask("换首图", in: nil)
    let shot = try await store.createCard(in: nil, body: "候选图截图")
    let other = try await store.createCard(in: nil, body: "别的灵感")

    try await store.moveCard(shot.id, to: .under(task.id), after: nil)
    let sub = try await store.createTask("裁成 16:9", under: task.id)

    #expect(try await store.children(of: task.id).map(\.id) == [shot.id, sub.id])
    #expect(try await card(shot.id).isTask == false)
    await #expect(throws: CueStoreError.invalidParent) { try await store.moveCard(other.id, to: .under(shot.id), after: nil) }
    await #expect(throws: CueStoreError.invalidParent) { try await store.createTask("x", under: shot.id) }
  }

  @Test func 取消要做与进回收站_下级按原顺序提到它的位置() async throws {
    let top = try await store.createTask("上线", in: nil)
    let before = try await store.createTask("前一条", under: top.id)
    let parent = try await store.createTask("备份", under: top.id)
    let material = try await store.createCard(in: nil, body: "备份脚本")
    try await store.moveCard(material.id, to: .under(parent.id), after: nil)
    let sub = try await store.createTask("导出", under: parent.id)
    let after = try await store.createTask("后一条", under: top.id)

    try await store.setTodo(parent.id, false)
    #expect(try await store.children(of: top.id).map(\.id) == [before.id, parent.id, material.id, sub.id, after.id])

    try await store.setTodo(parent.id, true)
    try await store.moveCard(sub.id, to: .under(parent.id), after: nil)
    try await store.trashCard(parent.id)
    #expect(try await store.children(of: top.id).map(\.id) == [before.id, sub.id, material.id, after.id])
    #expect(try await card(parent.id).deletedAt != nil)
  }

  @Test func 交给Agent的任务关联会话并进行中_灵感发出去不变成任务() async throws {
    let task = try await store.createTask("修重连", in: nil)
    let idea = try await store.createCard(in: nil, body: "随便问问")
    try await store.recordSend("修重连", to: SendTarget(kind: .piSession, name: "atlas", ref: "s1"), card: task.id)
    try await store.recordSend("随便问问", to: SendTarget(kind: .piSession, name: "atlas", ref: "s1"), card: idea.id)

    let sent = try await card(task.id)
    #expect(sent.status == .inProgress && sent.piSessionID == "s1")
    let unsent = try await card(idea.id)
    #expect(unsent.isTask == false && unsent.piSessionID == nil)
  }

  @Test func 计数只算顶层任务_素材与灵感不算() async throws {
    let project = try await store.createProject(name: "圆桌", color: "#111")
    let top = try await store.createTask("上线", in: project.id)
    let material = try await store.createCard(in: project.id, body: "截图")
    try await store.moveCard(material.id, to: .under(top.id), after: nil)
    _ = try await store.createTask("备份", under: top.id)
    _ = try await store.createCard(in: project.id, body: "灵感")

    #expect(try await store.taskCounts()[project.id] == TaskCounts(inProgress: 0, todo: 1, done: 0))
    #expect(TaskProgress.subtasks(in: try await store.childMarks()[top.id]) == TaskProgress(done: 0, total: 1))
    #expect(try await store.tasks(.todo).flatMap(\.tasks).map(\.body) == ["上线", "备份"])
  }

  @Test func 项目只有一句话介绍() async throws {
    let project = try await store.createProject(name: "圆桌", color: "#111")
    try await store.updateProject(project.id) { $0.intro = "多 Agent 调度" }
    #expect(try await store.project(project.id)?.intro == "多 Agent 调度")
  }
}
