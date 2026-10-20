import CueStore
import Foundation
import Testing

@Suite struct ObservationTests {
  let fixture = try! Fixture()

  @Test func observersGetCurrentValueThenEachRelevantCommit() async throws {
    let store = fixture.store
    let project = try await store.createProject(name: "P", color: "#111")
    var values = store.observe { try bodies($0.cards(in: project.id)) }
      .makeAsyncIterator()
    #expect(try await values.next() == [])

    _ = try await store.createCard(in: project.id, body: "hello")
    #expect(try await values.next() == ["hello"])

    try await store.trashProject(project.id)  // 项目表变化让卡片列表重读
    #expect(try await values.next() == [])
  }

  /// 订阅以表为粒度：同一张表里别的行改了，重读的结果和上一次一样就不再产出（界面不会为没变的数据重算）。
  @Test(.timeLimit(.minutes(1))) func resultThatDidNotChangeIsNotDeliveredAgain() async throws {
    let store = fixture.store
    let a = try await store.createProject(name: "A", color: "#111")
    let (reads, readSignal) = AsyncStream<Void>.makeStream()
    var read = reads.makeAsyncIterator()
    var values = store.observe { store -> String in
      readSignal.yield()
      return try store.project(a.id)?.name ?? ""
    }.makeAsyncIterator()
    #expect(try await values.next() == "A")
    await read.next()

    _ = try await store.createProject(name: "B", color: "#222")  // 同一张表，A 没变
    await read.next()  // 订阅者已为它重读过一次
    try await store.updateProject(a.id) { $0.name = "A2" }
    #expect(try await values.next() == "A2")  // 中间那次重读没有再产出一个 "A"
  }

  /// 重新订阅时调用方手里已有的值当作"上一次"：第一份读到的没变就不产出，界面不为它再写一遍、再算一遍。
  @Test(.timeLimit(.minutes(1))) func valueTheCallerAlreadyHoldsIsNotDeliveredAgain() async throws {
    let store = fixture.store
    let (reads, readSignal) = AsyncStream<Void>.makeStream()
    var read = reads.makeAsyncIterator()
    var values = store.observe(after: 0) { store -> Int in
      readSignal.yield()
      return try store.cards(in: Project.defaultID).count
    }.makeAsyncIterator()
    await read.next()  // 第一次读到的是 0，和手里的一样：不产出

    _ = try await store.createCard(body: "x")
    #expect(try await values.next() == 1)
  }
}
