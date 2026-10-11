import CueStore
import Foundation
import Testing

@Suite struct SendTimeTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  // MARK: 最近发送时间

  @Test func lastSendsBatchesLatestSendWithItsTargetPerVisibleCardOfTheProject() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    let a = try await store.createCard(in: p.id, body: "a")
    let b = try await store.createCard(in: p.id, body: "b")
    let neverSent = try await store.createCard(in: p.id, body: "never")
    let trashed = try await store.createCard(in: p.id, body: "trashed")
    let unfiled = try await store.createCard(in: nil, body: "unfiled")
    let review = SendTarget(kind: .piSession, name: "review", ref: "s2")
    let pi = SendTarget(kind: .piSession, name: "fix bug", ref: "s1")

    let old = try await store.recordSend("a", to: review, card: a.id)
    try await Task.sleep(for: .milliseconds(3))  // 时间精度是毫秒
    let latest = try await store.recordSend("a again", to: pi, card: a.id)
    let onlyOnce = try await store.recordSend("b", to: review, card: b.id)
    try await store.recordSend("t", to: review, card: trashed.id)
    try await store.recordSend("i", to: review, card: unfiled.id)
    try await store.recordSend("loose", to: review)  // 没关联卡片
    try await store.trashCard(trashed.id)

    let sends = try await store.lastSends(in: p.id)

    #expect(Set(sends.keys) == [a.id, b.id])  // 未发送、回收站、别的项目的卡都不出现
    #expect(sends[a.id]?.sentAt == latest.sentAt && latest.sentAt > old.sentAt)
    #expect(sends[a.id]?.target == pi)  // 最近一次发给谁
    #expect(sends[b.id] == LastSend(sentAt: onlyOnce.sentAt, target: review))
    #expect(try await store.lastSends(in: nil).keys.contains(unfiled.id))
    _ = neverSent
  }

  @Test func lastSendsChangesWakeObservers() async throws {
    let p = try await store.createProject(name: "P", color: "#111")
    let card = try await store.createCard(in: p.id, body: "a")
    var values = store.observe { try Set($0.lastSends(in: p.id).keys) }
      .makeAsyncIterator()
    #expect(try await values.next() == [])

    try await store.recordSend("a", to: SendTarget(kind: .piSession, name: "x", ref: "x"), card: card.id)
    #expect(try await values.next() == [card.id])
  }

  // MARK: 发送目标列表

  @Test func sendTargetsAreDistinctByKindAndNameOrderedByRecentUse() async throws {
    let card = try await store.createCard(in: nil, body: "c")
    let goneCard = try await store.createCard(in: nil, body: "gone")
    func send(_ content: String, _ kind: SendTargetKind, _ name: String, ref: String? = nil, at seconds: Int, card: UUID?) async throws {
      try await store.recordSend(content, to: SendTarget(kind: kind, name: name, ref: ref), card: card)
      try RawDB(fixture.url).exec("UPDATE sendRecords SET sentAt = \(seconds * 1000) WHERE content = '\(content)'")
    }
    try await send("1", .piSession, "review", ref: "r1", at: 100, card: card.id)
    try await send("2", .piSession, "notes", ref: "n1", at: 200, card: card.id)
    try await send("3", .piSession, "fix bug", ref: "old-id", at: 300, card: card.id)
    try await send("4", .piSession, "fix bug", ref: "new-id", at: 500, card: card.id)  // 同一目标再次使用
    try await send("6", .piSession, "Loose", at: 900, card: nil)  // 没有关联卡片，不能筛出任何卡
    try await send("7", .piSession, "Purged", at: 800, card: goneCard.id)
    try await store.purgeCard(goneCard.id)

    let targets = try await store.sendTargets()

    #expect(targets == [
      SendTarget(kind: .piSession, name: "fix bug", ref: "new-id"),  // ref 取该目标最近一次的
      SendTarget(kind: .piSession, name: "notes", ref: "n1"),
      SendTarget(kind: .piSession, name: "review", ref: "r1"),
    ])
  }
}
