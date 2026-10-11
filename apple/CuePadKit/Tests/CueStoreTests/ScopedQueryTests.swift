import CueStore
import CueTestSupport
import Foundation
import Testing

/// 界面按范围读取的查询（回收站条数、一个项目的任务与下级、一批会话），结果要与全量查询再筛出来的一样。
@Suite struct ScopedQueryTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  @Test func 回收站条数是删除的项目加单独删除的卡片() async throws {
    let doomed = try await store.createProject(name: "删掉的", color: "#111")
    let kept = try await store.createProject(name: "留着的", color: "#111")
    let inDoomed = try await store.createCard(in: doomed.id, body: "随项目")
    let single = try await store.createCard(in: kept.id, body: "单独删")
    _ = try await store.createCard(in: kept.id, body: "活着")
    try await store.trashCard(single.id)
    try await store.trashProject(doomed.id)

    #expect(try await store.trashCount() == 2)  // 随项目删除的卡不单独数
    #expect(try await store.trashCount() == store.trashedProjects().count + store.trashedCards().count)
    try await store.purgeProject(doomed.id)
    #expect(try await store.card(inDoomed.id) == nil)
    #expect(try await store.trashCount() == 1)
  }

  @Test func 一个项目的任务与下级_等于全库的再按项目筛() async throws {
    let a = try await store.createProject(name: "A", color: "#111")
    let b = try await store.createProject(name: "B", color: "#111")
    let release = try await store.createTask("上线", in: a.id)
    let step = try await store.createTask("备份", under: release.id)
    _ = try await store.createCard(body: "提示词", under: release.id)
    try await store.setStatus(step.id, .done)
    let other = try await store.createTask("别处", in: b.id)
    _ = try await store.createCard(body: "别处的提示词", under: other.id)
    let loose = try await store.createTask("散的", in: nil)
    _ = try await store.createTask("散的子任务", under: loose.id)

    for project in [a.id, b.id, nil] {
      let all = try await store.tasks(.inProgress, .todo, .done).flatMap(\.tasks).filter { $0.projectID == project }
      #expect(try await store.tasks(in: project, .inProgress, .todo, .done) == all)
      let open = all.filter { $0.status != .done }
      #expect(try await store.tasks(in: project, .inProgress, .todo) == open)

      let marks = try await store.childMarks().filter { parent, _ in all.contains { $0.id == parent } }
      #expect(try await store.childMarks(in: project) == marks)
    }
    #expect(try await store.childMarks(of: release.id).keys.sorted { $0.uuidString < $1.uuidString } == [release.id])
    #expect(try await store.childMarks(of: release.id)[release.id]?.count == 2)
  }

  @Test func 一批会话的列表项_等于分页查询里的同一项() async throws {
    let project = try await store.createProject(name: "P", color: "#111")
    try await store.setDirectory("/work/p", for: project.id)
    let recorder = PiStateRecorder(store: store, hostID: "mac")
    try await recorder.update(sessionID: "s1", state: .thinking, title: "一号")
    try await recorder.update(sessionID: "s2", state: .settled, title: "二号")
    try await recorder.update(sessionID: "s3", state: .settled, title: "三号")
    try await store.upsertPiSession(PiSession(id: "s1", path: "/s/1", cwd: "/work/p/x", lastActivityAt: .now), host: "mac")
    try await store.requestDelivery("hi", to: SendTarget(kind: .piSession, name: "二号", ref: "s2"), on: "mac")

    let page = try await store.piSessionPage(PiSessionQuery(limit: .max)).items
    let picked = try await store.piSessions(sessionIDs: ["s1", "s2", "missing"])

    #expect(picked.keys.sorted() == ["s1", "s2"])
    #expect(picked["s1"] == page.first { $0.state.sessionID == "s1" })
    #expect(picked["s2"] == page.first { $0.state.sessionID == "s2" })
    #expect(picked["s2"]?.delivery != nil)
    #expect(try await store.piSessions(sessionIDs: []).isEmpty)
  }
}
