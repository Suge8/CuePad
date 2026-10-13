import CueStore
import Foundation
import Testing

/// 一件事由 Cue 跟进还是你自己（`Card.cueFollows`）。
@Suite struct CueFollowTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  /// 你经 CuePad 亲自对 Cue 跟进的叶子会话说话：任务收回给你，Cue 下次醒来和上次的看板一比就知道是你接手了；Cue 自己说的话不收回。
  @Test func speakingInAFollowedSessionTakesTheTaskBack() async throws {
    let task = try await store.createTask("发布", in: nil)
    let step = try await store.createTask("改脚本", under: task.id)
    try await store.linkCard(step.id, toSession: "s1")
    try await store.setCueFollows(step.id, true)
    let target = SendTarget(kind: .piSession, name: "改脚本", ref: "s1")

    let since = Date()
    let followed = Set(try await store.cueBoard().map(\.id))
    let fromCue = try await store.requestDelivery("接着改", to: target, on: "mac", cue: true)
    #expect(fromCue.isFromCue)
    #expect(try await store.card(task.id)?.cueFollows == true)

    let mine = try await store.requestDelivery("我来吧", to: target, on: "mac")
    #expect(mine.origin == nil)
    #expect(try await store.card(task.id)?.cueFollows == false)
    let changes = try await store.cueChanges(since: since, followed: followed)
    #expect(changes.map(\.kind) == [.left] && changes.first?.detail == "你接手了")
    #expect(try await store.cueChanges(since: since).isEmpty)  // 不给上次的看板就不比
  }

  /// 你把一件事交给 Cue，Cue 醒来看到它加入；它完成了只报完成，不另报不再跟进。
  @Test func joiningAndFinishingShowAsJoinedThenDone() async throws {
    let task = try await store.createTask("写周报", in: nil)
    let since = Date()
    try await store.setCueFollows(task.id, true)
    #expect(try await store.cueChanges(since: since, followed: []).map(\.kind) == [.joined])

    try await store.setStatus(task.id, .done)
    #expect(try await store.cueChanges(since: since, followed: [task.id]).map(\.kind) == [.done])
  }

  /// 只有顶层任务能由 Cue 跟进：挂到别的任务下就不再是。
  @Test func aFollowedTaskMovedUnderAnotherIsNoLongerFollowed() async throws {
    let parent = try await store.createTask("上线", in: nil)
    let task = try await store.createTask("发布", in: nil)
    try await store.setCueFollows(task.id, true)
    try await store.moveCard(task.id, to: .under(parent.id), after: nil)
    #expect(try await store.card(task.id)?.cueFollows == false)
    #expect(try await store.cueBoard().isEmpty)
  }
}
