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

  // MARK: 发送目标列表

}
