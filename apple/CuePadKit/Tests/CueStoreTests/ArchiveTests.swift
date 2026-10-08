import CueStore
import CueTestSupport
import Foundation
import Testing

/// 生命周期：活跃 → 归档（做完或不再需要，留着可搜、不占列表）→ 回收站。归档是 `archivedAt`，带着下级一起归档、一起取回。
/// 交给 Agent 的灵感与任务都记着那个会话，手机上发出还没执行时也认得出交给了谁。
@Suite struct ArchiveTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  @Test func 归档的灵感与任务不占列表_仍可搜到_取回后回到原处() async throws {
    let project = try await store.createProject(name: "圆桌", color: "#111")
    let idea = try await store.createCard(in: project.id, body: "接口约定")
    let task = try await store.createTask("上线", in: project.id)

    try await store.archive(idea.id)
    try await store.archive(task.id)

    #expect(try await store.cards(in: project.id).isEmpty)
    #expect(try await store.tasks(.todo).isEmpty)
    #expect(try await store.taskCounts()[project.id] == nil)
    #expect(try await store.search("接口约定").cards.map(\.id) == [idea.id])
    #expect(Set(try await store.archived().map(\.id)) == [idea.id, task.id])

    try await store.unarchive(idea.id)
    #expect(try await store.cards(in: project.id).map(\.id) == [idea.id])
    #expect(try await store.archived().map(\.id) == [task.id])
  }

  @Test func 归档任务连同下级一起_一键全部归档只动已完成的顶层任务() async throws {
    let done = try await store.createTask("上线", in: nil)
    let sub = try await store.createTask("备份", under: done.id)
    let prompt = try await store.createCard(in: nil, body: "日志")
    try await store.moveCard(prompt.id, to: .under(done.id), after: nil)
    try await store.setStatus(done.id, .done)
    let open = try await store.createTask("还在做", in: nil)
    // 没做完的任务下已完成的子任务算在上级的进度里，不单独归档
    let doneStep = try await store.createTask("已复现", under: open.id)
    try await store.setStatus(doneStep.id, .done)

    #expect(try await store.archiveCompletedTasks() == 1)
    #expect(try await store.card(doneStep.id)?.archivedAt == nil)

    for id in [done.id, sub.id, prompt.id] { #expect(try await store.card(id)?.archivedAt != nil) }
    #expect(try await store.card(open.id)?.archivedAt == nil)
    #expect(try await store.archived().map(\.id) == [done.id])
    #expect(try await store.tasks(.done).flatMap(\.tasks).map(\.id) == [doneStep.id])

    try await store.unarchive(done.id)
    for id in [done.id, sub.id, prompt.id] { #expect(try await store.card(id)?.archivedAt == nil) }
  }

  @Test func 灵感交给Agent也记下那个会话_手机发出还没执行时按请求认出() async throws {
    let idea = try await store.createCard(in: nil, body: "看一下重连")
    let queued = try await store.createCard(in: nil, body: "排期")
    let atlas = SendTarget(kind: .piSession, name: "atlas", ref: "s1")

    try await store.recordSend(idea.body, to: atlas, card: idea.id)
    _ = try await store.requestDelivery(queued.body, to: SendTarget(kind: .piSession, name: "notes", ref: "s2"), on: "mac-a", card: queued.id)

    let sent = try #require(try await store.card(idea.id))
    #expect(sent.piSessionID == "s1" && sent.status == nil)
    #expect(try await store.handedSessions() == [idea.id: .session("s1"), queued.id: .session("s2")])
  }
}
