import CueStore
import CueTestSupport
import Foundation
import Testing

/// 界面按范围读取的查询（回收站条数、一个项目的任务与下级），结果要与全量查询再筛出来的一样。
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
    try await store.moveCard(try await store.createCard(body: "资料").id, to: .under(release.id), after: nil)
    try await store.setStatus(step.id, .done)
    let other = try await store.createTask("别处", in: b.id)
    try await store.moveCard(try await store.createCard(body: "别处的资料").id, to: .under(other.id), after: nil)
    let loose = try await store.createTask("散的")
    _ = try await store.createTask("散的步骤", under: loose.id)

    for project in [a.id, b.id, Project.defaultID] {
      let all = try await store.tasks(.inProgress, .todo, .done).flatMap(\.tasks).filter { $0.projectID == project }
      #expect(try await store.tasks(in: project, .inProgress, .todo, .done) == all)
      let open = all.filter { $0.status != .done }
      #expect(try await store.tasks(in: project, .inProgress, .todo) == open)

      let progress = try await store.subtaskProgress().filter { parent, _ in all.contains { $0.id == parent } }
      #expect(try await store.subtaskProgress(in: project) == progress)
    }
    // 只算步骤：上线下面一条已完成的步骤加一条提示词，进度是 1/1
    #expect(try await store.subtaskProgress(of: [release.id]) == [release.id: TaskProgress(done: 1, total: 1)])
  }
}
