import CueStore
import Foundation
import Testing

@Suite struct TrashCountTests {
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
    try await store.purgeProject(doomed.id)
    #expect(try await store.card(inDoomed.id) == nil)
    #expect(try await store.trashCount() == 1)
  }
}
