import CueStore
import Foundation
import Testing

@Suite struct ObservationTests {
  let fixture = try! Fixture()

  @Test func observersGetCurrentValueThenEachRelevantCommit() async throws {
    let store = fixture.store
    let project = try await store.createProject(name: "P", color: "#111")
    var values = store.observe([.cards, .projects]) { try bodies($0.cards(in: project.id)) }
      .makeAsyncIterator()
    #expect(try await values.next() == [])

    _ = try await store.createCard(in: project.id, body: "hello")
    #expect(try await values.next() == ["hello"])

    try await store.trashProject(project.id)  // 项目表变化让卡片列表重读
    #expect(try await values.next() == [])
  }
}
