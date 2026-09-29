import CueStore
import Foundation
import Testing

@Suite struct GoalAndSendTimeTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  private func goal(of project: Project) async throws -> UUID? {
    try await store.project(project.id)?.goalCardID
  }

  // MARK: 项目目标卡

  @Test func goalCardIsSetAndClearedExplicitly() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    let card = try await store.createCard(in: p.id, body: "goal")
    #expect(try await goal(of: p) == nil)

    try await store.setGoal(card.id, for: p.id)
    #expect(try await goal(of: p) == card.id)

    try await store.setGoal(nil, for: p.id)
    #expect(try await goal(of: p) == nil)
  }

  @Test func goalMustBeALiveCardOfThatProject() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    let q = try await store.createProject(name: "Q", color: "#222")
    let foreign = try await store.createCard(in: q.id, body: "foreign")
    let inbox = try await store.createCard(in: nil, body: "inbox")
    let trashed = try await store.createCard(in: p.id, body: "trashed")
    try await store.trashCard(trashed.id)

    for card in [foreign, inbox, trashed] {
      await #expect(throws: CueStoreError.invalidGoal) { try await store.setGoal(card.id, for: p.id) }
    }
    await #expect(throws: CueStoreError.invalidGoal) { try await store.setGoal(UUID(), for: p.id) }
    #expect(try await goal(of: p) == nil)
  }

  @Test func goalIsClearedWhenItsCardIsTrashedPurgedOrMovedAway() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    let other = try await store.createProject(name: "Other", color: "#222")
    let untouched = try await store.createCard(in: other.id, body: "other goal")
    try await store.setGoal(untouched.id, for: other.id)

    func newGoal() async throws -> Card {
      let card = try await store.createCard(in: p.id, body: "goal")
      try await store.setGoal(card.id, for: p.id)
      return card
    }

    try await store.trashCard(try await newGoal().id)
    #expect(try await goal(of: p) == nil)

    try await store.purgeCard(try await newGoal().id)
    #expect(try await goal(of: p) == nil)

    try await store.moveCard(try await newGoal().id, to: nil, after: nil)
    #expect(try await goal(of: p) == nil)

    #expect(try await store.project(other.id)?.goalCardID == untouched.id)
  }

  @Test func goalSurvivesMovingWithinTheSameProject() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    let first = try await store.createCard(in: p.id, body: "1")
    let second = try await store.createCard(in: p.id, body: "2")
    try await store.setGoal(second.id, for: p.id)

    try await store.moveCard(second.id, to: p.id, after: first.id)

    #expect(try await goal(of: p) == second.id)
  }

  // MARK: 最近发送时间

  @Test func lastSentTimesBatchesLatestSendPerVisibleCardOfTheProject() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    let a = try await store.createCard(in: p.id, body: "a")
    let b = try await store.createCard(in: p.id, body: "b")
    let neverSent = try await store.createCard(in: p.id, body: "never")
    let trashed = try await store.createCard(in: p.id, body: "trashed")
    let inbox = try await store.createCard(in: nil, body: "inbox")
    let target = SendTarget(kind: .clipboard, name: "clipboard")

    let old = try await store.recordSend("a", to: target, card: a.id)
    try await Task.sleep(for: .milliseconds(3))  // 时间精度是毫秒
    let latest = try await store.recordSend("a again", to: target, card: a.id)
    let onlyOnce = try await store.recordSend("b", to: target, card: b.id)
    try await store.recordSend("t", to: target, card: trashed.id)
    try await store.recordSend("i", to: target, card: inbox.id)
    try await store.recordSend("loose", to: target)  // 没关联卡片
    try await store.trashCard(trashed.id)

    let times = try await store.lastSentTimes(in: p.id)

    #expect(Set(times.keys) == [a.id, b.id])  // 未发送、回收站、别的项目的卡都不出现
    #expect(times[a.id] == latest.sentAt && latest.sentAt > old.sentAt)
    #expect(times[b.id] == onlyOnce.sentAt)
    #expect(try await store.lastSentTimes(in: nil).keys.contains(inbox.id))
    _ = neverSent
  }

  @Test func lastSentTimesChangesWakeObservers() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    let card = try await store.createCard(in: p.id, body: "a")
    var values = store.observe([.sendRecords, .cards]) { try Set($0.lastSentTimes(in: p.id).keys) }
      .makeAsyncIterator()
    #expect(try await values.next() == [])

    try await store.recordSend("a", to: SendTarget(kind: .app, name: "x"), card: card.id)
    #expect(try await values.next() == [card.id])
  }
}
