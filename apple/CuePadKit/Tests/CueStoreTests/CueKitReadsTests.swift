import CueStore
import Foundation
import Testing

/// 管理器与界面直接读的几项：待交给大脑的、跟进的会话、批量预览、记忆的版本读数、跟进会话的手机推送。
@Suite struct CueKitReadsTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  /// 待交给大脑的：你说了没交的话、"等你"上没交的回答；交过的不再交。
  @Test func whatIsLeftToDeliverToTheBrain() async throws {
    let said = try await store.addCueMessage(.you, text: "看看发布")
    let asked = try await store.addCueMessage(.cue, text: "合并吗？", ask: .merge)
    try await store.addCueMessage(.cue, text: "开工了")
    #expect(try await store.cueMessagesToDeliver().map(\.id) == [said.id])

    try await store.endCueQuestion(asked.id, .answered(CueAsk.once))
    #expect(try await store.cueMessagesToDeliver().map(\.id) == [said.id, asked.id])
    try await store.markCueMessagesDelivered([said.id, asked.id])
    #expect(try await store.cueMessagesToDeliver().isEmpty)
  }

  /// 跟进的会话：Cue 跟进的任务自己的会话与它的步骤的会话；你自己做的不算。
  @Test func sessionsOfFollowedTasksIncludingTheirSteps() async throws {
    let followed = try await store.createTask("发布", in: nil)
    let step = try await store.createTask("改脚本", under: followed.id)
    let leaf = try await store.createTask("写周报", in: nil)
    let mine = try await store.createTask("自己做", in: nil)
    for (card, session) in [(step, "s1"), (leaf, "s2"), (mine, "s3")] { try await store.linkCard(card.id, toSession: session) }
    try await store.setCueFollows(followed.id, true)
    try await store.setCueFollows(leaf.id, true)
    #expect(try await store.cueFollowedSessions() == ["s1", "s2"])
  }

  /// Cue 跟进的会话弹出提问不给手机推"等你确认"（Cue 处理）；你自己的照推。
  @Test func followedSessionsDoNotPushWaitingForYou() async throws {
    let followed = try await store.createTask("发布", in: nil)
    let mine = try await store.createTask("自己做", in: nil)
    try await store.linkCard(followed.id, toSession: "s1")
    try await store.linkCard(mine.id, toSession: "s2")
    try await store.setCueFollows(followed.id, true)
    let recorder = PiStateRecorder(store: store, hostID: "mac")
    for session in ["s1", "s2"] {
      try await recorder.update(sessionID: session, state: .thinking)
      try await recorder.update(sessionID: session, state: .waitingForUser, question: PiQuestion(promptID: "p", kind: .confirm, text: "继续？"))
    }
    let states = try await store.piSessions(sessionIDs: ["s1", "s2"])
    #expect(states["s1"]?.state.notify == nil)
    #expect(states["s2"]?.state.notify == .known(.waitingForUser))
  }

  /// 一批任务的预览一次取：任务自己的会话与步骤的会话发的都算在任务上。
  @Test func previewsOfManyTasksAtOnce() async throws {
    let top = try await store.createTask("发布", in: nil)
    let step = try await store.createTask("截图", under: top.id)
    let other = try await store.createTask("写周报", in: nil)
    try await store.linkCard(step.id, toSession: "s1")
    try await store.linkCard(other.id, toSession: "s2")
    for (session, name) in [("s1", "a.html"), ("s2", "b.html")] {
      let file = fixture.directory.appending(path: name)
      try Data("<p>\(name)</p>".utf8).write(to: file)
      _ = try await store.addPreviews(filesAt: [file], title: name, sessionID: session)
    }
    let previews = try await store.previews(ofTasks: [top.id, other.id])
    #expect(previews[top.id]?.map(\.name) == ["a.html"] && previews[other.id]?.map(\.name) == ["b.html"])
  }

  /// 记忆的版本读数随记、忘、写摘要而变。
  @Test func memoryVersionMovesWithEveryChange() async throws {
    var seen = [try await store.cueMemoryVersion()]
    for index in 0..<2 { try await store.noteCueLine("第 \(index) 条", source: .cue) }
    seen.append(try await store.cueMemoryVersion())
    try await Task.sleep(for: .milliseconds(2))
    try await store.forgetCueLine(try #require(try await store.cueLine(at: 0)).id)
    seen.append(try await store.cueMemoryVersion())
    try await store.setCueSummary(lo: 0, hi: 2, text: "两条")
    seen.append(try await store.cueMemoryVersion())
    #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 != $1 })
  }
}
