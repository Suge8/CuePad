import CueStore
import Foundation
import Testing

/// 空白灵感离开编辑就不留下、不计数（真实库里留着过正文为空的灵感）。
@Suite struct BlankContentTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  @Test func 空白灵感离开编辑就不留下_写了字的与任务都留着() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    let blank = try await store.createCard(in: p.id)
    let spaces = try await store.createCard(in: p.id, body: " \n\n ")
    let kept = try await store.createCard(in: p.id, body: "换首图")
    let task = try await store.createTask("修乱序", in: p.id)

    for id in [blank.id, spaces.id, kept.id, task.id] { try await store.dropIfBlank(id) }

    #expect(try await store.card(blank.id) == nil)
    #expect(try await store.card(spaces.id) == nil)
    #expect(try await store.card(kept.id) != nil)
    #expect(try await store.card(task.id) != nil)
  }

}
