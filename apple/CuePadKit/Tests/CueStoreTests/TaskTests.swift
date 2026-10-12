import CueStore
import CueTestSupport
import Foundation
import Testing

/// 灵感与任务是同一种记录（Card）：差别只是"要做"（`todoAt`）。任务三态、可有子任务（任务最多两级）与提示词（挂在任务下的灵感）；
/// 只有任务能当上级；去掉"要做"或进回收站时，下级按原顺序提到它的位置；归档连同下级。
@Suite struct TaskTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  private func card(_ id: UUID) async throws -> Card { try #require(try await store.card(id)) }

  @Test func 灵感设为任务_三态_层级_完成上级连带下级_数字只算顶层() async throws {
    let project = try await store.createProject(name: "圆桌", color: "#111")
    let idea = try await store.createCard(in: project.id, body: "把发言轮次修好")
    let fresh = try await card(idea.id)
    #expect(fresh.isTask == false && fresh.status == nil)

    try await store.setTodo(idea.id, true)
    try await store.setStatus(idea.id, .inProgress)
    let started = try await card(idea.id)
    #expect(started.status == .inProgress && started.startedAt != nil && started.completedAt == nil)
    try await store.setStatus(idea.id, .done)
    let done = try await card(idea.id)
    #expect(done.status == .done && done.completedAt != nil && done.startedAt == started.startedAt)
    try await store.setStatus(idea.id, .todo)
    let reopened = try await card(idea.id)
    #expect(reopened.status == .todo && reopened.startedAt == nil && reopened.completedAt == nil)
    try await store.setTodo(idea.id, false)
    let back = try await card(idea.id)
    #expect(back.isTask == false && back.status == nil && back.body == "把发言轮次修好")

    // 层级：只有任务能当上级，灵感挂在任务下是提示词；子任务跟随上级的项目，任务最多两级、提示词挂在任一级任务下不算一级
    let top = try await store.createTask("修重连", in: project.id)
    let shot = try await store.createCard(in: nil, body: "候选图截图")
    try await store.moveCard(shot.id, to: .under(top.id), after: nil)
    let second = try await store.createTask("改排序", under: top.id)
    let third = try await store.createCard(body: "补用例", under: second.id)
    #expect(try await store.children(of: top.id).map(\.id) == [shot.id, second.id])
    #expect(second.projectID == project.id && third.parentID == second.id && third.projectID == project.id)
    await #expect(throws: CueStoreError.invalidParent) { try await store.moveCard(idea.id, to: .under(shot.id), after: nil) }
    await #expect(throws: CueStoreError.invalidParent) { try await store.createTask("x", under: shot.id) }
    await #expect(throws: CueStoreError.taskTooDeep) { try await store.createTask("第三级", under: second.id) }
    await #expect(throws: CueStoreError.taskTooDeep) { try await store.setTodo(third.id, true) }  // 子任务下的提示词不能升成第三级任务

    // 完成上级：没完成的下级一起完成，已完成的保留原时间；重新打开上级不动下级
    let finished = try await store.createTask("写说明", under: top.id)
    try await store.setStatus(finished.id, .done)
    let finishedAt = try #require(try await card(finished.id).completedAt)
    try await store.setStatus(top.id, .done)
    for id in [top.id, second.id] { #expect(try await card(id).status == .done) }
    #expect(try await card(finished.id).completedAt == finishedAt)
    try await store.setStatus(top.id, .todo)
    #expect(try await card(second.id).status == .done)

    // 给用户看的数字只按顶层任务计：上级已完成而自己重新打开的子任务算顶层
    try await store.setStatus(top.id, .done)
    try await store.setStatus(second.id, .todo)
    #expect(try await store.taskCounts()[project.id] == TaskCounts(inProgress: 0, todo: 1, done: 1))
  }

  @Test func 移动_不能成环或任务超两级_换项目带着子树_取消要做与进回收站时下级上提() async throws {
    let site = try await store.createProject(name: "网站", color: "#111")
    let table = try await store.createProject(name: "圆桌", color: "#111")
    let a = try await store.createTask("a", in: nil)
    let a1 = try await store.createTask("a1", under: a.id)
    let b = try await store.createTask("b", in: nil)
    let b1 = try await store.createTask("b1", under: b.id)

    await #expect(throws: CueStoreError.invalidParent) { try await store.moveCard(a.id, to: .under(a1.id), after: nil) }
    await #expect(throws: CueStoreError.taskTooDeep) { try await store.moveCard(a.id, to: .under(b1.id), after: nil) }
    #expect(try await card(a.id).parentID == nil)
    let note = try await store.createCard(in: nil, body: "备注")
    try await store.moveCard(note.id, to: .under(b1.id), after: nil)  // 提示词挂在第二级任务下
    #expect(try await card(note.id).parentID == b1.id)

    // 挂到别的项目的任务下：整棵子树换到那个项目，同级按放的位置排
    let moving = try await store.createTask("换首图", in: site.id)
    let child = try await store.createCard(body: "裁图", under: moving.id)
    let parent = try await store.createTask("上线", in: table.id)
    let first = try await store.createTask("备份", under: parent.id)
    let last = try await store.createTask("发布", under: parent.id)
    try await store.moveCard(moving.id, to: .under(parent.id), after: first.id)
    #expect(try await store.children(of: parent.id).map(\.id) == [first.id, moving.id, last.id])
    #expect(try await card(child.id).projectID == table.id)

    // 取消要做、进回收站：下级按原顺序提到它的位置
    let release = try await store.createProject(name: "发布", color: "#111")
    let after = try await store.createTask("后一条", in: release.id)
    let middle = try await store.createTask("备份", in: release.id)
    let before = try await store.createTask("前一条", in: release.id)
    let prompt = try await store.createCard(in: nil, body: "备份脚本")
    try await store.moveCard(prompt.id, to: .under(middle.id), after: nil)
    let sub = try await store.createTask("导出", under: middle.id)
    func tasks() async throws -> [UUID] { try await store.tasks(.todo).flatMap(\.tasks).filter { $0.projectID == release.id }.map(\.id) }
    try await store.setTodo(middle.id, false)
    #expect(try await tasks() == [before.id, sub.id, after.id])
    let lifted = try await [card(prompt.id), card(sub.id)]
    #expect(lifted.allSatisfy { $0.parentID == nil && $0.projectID == release.id } && lifted[0].sortKey < lifted[1].sortKey)
    try await store.setTodo(middle.id, true)
    try await store.moveCard(sub.id, to: .under(middle.id), after: nil)
    try await store.trashCard(middle.id)
    #expect(try await tasks() == [before.id, sub.id, after.id])
  }

  @Test func 归档不占列表仍可搜到_连同下级一起取回_一键全部归档只动已完成的顶层任务() async throws {
    let project = try await store.createProject(name: "圆桌", color: "#111")
    let idea = try await store.createCard(in: project.id, body: "接口约定")
    try await store.archive(idea.id)
    #expect(try await store.cards(in: project.id).isEmpty)
    #expect(try await store.search("接口约定").cards.map(\.id) == [idea.id])
    try await store.unarchive(idea.id)
    #expect(try await store.cards(in: project.id).map(\.id) == [idea.id])

    let done = try await store.createTask("上线", in: nil)
    let sub = try await store.createTask("备份", under: done.id)
    let prompt = try await store.createCard(in: nil, body: "日志")
    try await store.moveCard(prompt.id, to: .under(done.id), after: nil)
    try await store.setStatus(done.id, .done)
    let open = try await store.createTask("还在做", in: nil)
    let doneStep = try await store.createTask("已复现", under: open.id)
    try await store.setStatus(doneStep.id, .done)  // 没做完的任务下已完成的子任务算在上级的进度里，不单独归档

    #expect(try await store.archiveCompletedTasks() == 1)
    for id in [done.id, sub.id, prompt.id] { #expect(try await card(id).archivedAt != nil) }
    for id in [open.id, doneStep.id] { #expect(try await card(id).archivedAt == nil) }
    try await store.unarchive(done.id)
    for id in [done.id, sub.id, prompt.id] { #expect(try await card(id).archivedAt == nil) }
  }

  @Test func 交给Agent的任务关联会话并进行中_灵感也记下会话但不变成任务() async throws {
    let task = try await store.createTask("修重连", in: nil)
    let idea = try await store.createCard(in: nil, body: "随便问问")
    let atlas = SendTarget(kind: .piSession, name: "atlas", ref: "s1")
    try await store.recordSend("修重连", to: atlas, card: task.id)
    try await store.recordSend("随便问问", to: atlas, card: idea.id)

    let sent = try await card(task.id)
    #expect(sent.status == .inProgress && sent.piSessionID == "s1")
    let handed = try await card(idea.id)
    #expect(handed.isTask == false && handed.status == nil && handed.piSessionID == "s1")
  }
}
