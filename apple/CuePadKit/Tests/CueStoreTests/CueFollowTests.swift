import CueStore
import Foundation
import Testing

/// 一件事由 Cue 跟进还是你自己（`Card.cueFollows`）。
@Suite struct CueFollowTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  /// Cue 请会话停下没能做到（会话所在的 Mac 报错）：是一条跟进变化，带上动作与原因；完成的请求过了保留期就清理，它也还在，
  /// Cue 醒来时一定看得到。你自己发起的请求失败了不报（界面上看得见）。
  @Test func aFailedRequestFromCueIsAChangeThatOutlivesCleanup() async throws {
    let task = try await store.createTask("发布", in: nil)
    try await store.linkCard(task.id, toSession: "s1")
    try await store.setCueFollows(task.id, true)
    try await PiStateRecorder(store: store, hostID: "mac").update(sessionID: "s1", state: .thinking)  // 正在跑一轮：停得了才发得出停下
    let since = CueMarks(try await store.lastWrite())
    let executor = DeliveryExecutor(store: store, hostID: "mac", retention: .milliseconds(1), onIssue: { Issue.record("\($0)") }) { _ in
      .failed("会话已关闭")
    }
    try await executor.start()
    defer { Task { await executor.stop() } }
    _ = try await store.stopLeaf(task.id, host: "mac", cue: true)
    let mine = try await store.requestEnd(of: SendTarget(kind: .piSession, name: "发布", ref: "s1"), on: "mac")
    _ = try await eventually(store, { try $0.deliveryRequest(mine.id) }) { $0 == nil }  // 清理过了

    let changes = try await store.cueChanges(after: since)
    #expect(changes.map(\.detail) == ["停下：会话已关闭"])
    #expect(changes.first?.taskID == task.id && changes.first?.leaf?.id == task.id)
  }

  /// 你经 CuePad 亲自对 Cue 跟进的叶子会话说话：任务收回给你，Cue 下次醒来和上次的看板一比就知道是你接手了；Cue 自己说的话不收回。
  @Test func speakingInAFollowedSessionTakesTheTaskBack() async throws {
    let task = try await store.createTask("发布", in: nil)
    let step = try await store.createTask("改脚本", under: task.id)
    try await store.linkCard(step.id, toSession: "s1")
    try await store.setCueFollows(step.id, true)
    let target = SendTarget(kind: .piSession, name: "改脚本", ref: "s1")

    let since = CueMarks(try await store.lastWrite())
    let followed = Set(try await store.cueBoard().map(\.id))
    let fromCue = try await store.requestDelivery("接着改", to: target, on: "mac", cue: true)
    #expect(fromCue.isFromCue)
    #expect(try await store.card(task.id)?.cueFollows == true)

    let mine = try await store.requestDelivery("我来吧", to: target, on: "mac")
    #expect(mine.origin == nil)
    #expect(try await store.card(task.id)?.cueFollows == false)
    let changes = try await store.cueChanges(after: since, followed: followed)
    #expect(changes.map(\.kind) == [.left] && changes.first?.detail == "你接手了")
    #expect(try await store.cueChanges(after: since).isEmpty)  // 不给上次的看板就不比
  }

  /// 一个会话绑着两件 Cue 跟进的事：你在终端里说的话两件都报；你经 CuePad 对它说话，两件都收回给你。
  @Test func aSessionSharedByTwoFollowedTasksCountsForBoth() async throws {
    let tasks = [try await store.createTask("发布", in: nil), try await store.createTask("写周报", in: nil)]
    for task in tasks {
      try await store.bindSession("s1", to: task.id)
      try await store.setCueFollows(task.id, true)
    }
    let since = CueMarks(try await store.lastWrite())
    try await Task.sleep(for: .milliseconds(2))
    try await store.writePiTranscript(PiTranscript(
      sessionID: "s1", messages: [PiChatMessage(sessionID: "s1", entryID: "u1", seq: 1, role: .user, text: "先停一下", at: .now)], recap: PiRecap()))
    let spoke = try await store.cueChanges(after: since).filter { $0.kind == .youSpoke }
    #expect(Set(spoke.map(\.taskID)) == Set(tasks.map(\.id)))

    _ = try await store.requestDelivery("我来吧", to: SendTarget(kind: .piSession, name: "s1", ref: "s1"), on: "mac")
    #expect(try await store.cueBoard().isEmpty)
  }

  /// 你把一件事交给 Cue，Cue 醒来看到它加入；它完成了只报完成（带会话的回复摘要），不另报不再跟进。
  @Test func joiningAndFinishingShowAsJoinedThenDone() async throws {
    let task = try await store.createTask("写周报", in: nil)
    try await store.linkCard(task.id, toSession: "s1")
    try await PiStateRecorder(store: store, hostID: "mac").update(sessionID: "s1", state: .settled, title: "写周报")
    try await store.writePiTranscript(PiTranscript(sessionID: "s1", messages: [], recap: PiRecap(lastPrompt: "写周报", lastReply: "周报写好了")))
    try await Task.sleep(for: .milliseconds(2))
    let since = CueMarks(try await store.lastWrite())
    try await store.setCueFollows(task.id, true)
    #expect(try await store.cueChanges(after: since, followed: []).map(\.kind) == [.joined])

    try await store.setStatus(task.id, .done)
    let changes = try await store.cueChanges(after: since, followed: [task.id])
    #expect(changes.map(\.kind) == [.done] && changes.first?.recap?.lastReply == "周报写好了")
  }

  /// 跟进中的任务被永久删除：Cue 醒来照样知道它不再跟进，是删了。
  @Test func aFollowedTaskPurgedShowsAsLeft() async throws {
    let task = try await store.createTask("清理旧分支", in: nil)
    try await store.setCueFollows(task.id, true)
    let since = CueMarks(try await store.lastWrite())
    try await store.purgeCard(task.id)
    let changes = try await store.cueChanges(after: since, followed: [task.id])
    #expect(changes.map(\.kind) == [.left] && changes.first?.taskID == task.id && changes.first?.detail == "删了")
  }

  /// 用户收下之后 Cue 把整件事完成：还有步骤没做完时不行（说还剩几个）；步骤都做完了，任务完成，各步骤上的会话请它结束——
  /// 只结束绑着的事都做完了的：一个会话还绑着别的没做完的事就留着，那件事完成（你点圆圈也一样）时才结束。
  @Test func aTaskWithStepsCompletesOnlyWhenEveryStepIsDone() async throws {
    let task = try await store.createTask("发布", in: nil)
    let steps = [try await store.createTask("改脚本", under: task.id), try await store.createTask("跑检查", under: task.id)]
    let other = try await store.createTask("写周报", in: nil)
    let recorder = PiStateRecorder(store: store, hostID: "mac")
    for (step, session) in zip(steps, ["s1", "s2"]) {
      try await store.linkCard(step.id, toSession: session)
      try await recorder.update(sessionID: session, state: .settled, title: session)
    }
    try await store.bindSession("s1", to: other.id)
    try await store.setStatus(steps[0].id, .done)
    await #expect(throws: CueStoreError.stepsRemaining(1)) { try await store.completeTask(task.id, requireStepsDone: true) }

    try await store.setStatus(steps[1].id, .done)
    let ends = try await store.completeTask(task.id, requireStepsDone: true)
    #expect(try await store.card(task.id)?.status == .done)
    #expect(ends.compactMap(\.target.ref) == ["s2"] && ends.allSatisfy { $0.mode == .known(.end) })
    #expect(try await store.toggleDone(other.id).ended.compactMap(\.target.ref) == ["s1"])
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

  /// "等你"由事实推出：关联的任务不再是没做完的（完成、归档、删了），那条就不再等你。
  @Test func aQuestionAboutATaskThatIsNoLongerOpenStopsWaiting() async throws {
    let project = try await store.createProject(name: "演示", color: "blue")
    let tasks = [
      try await store.createTask("完成的", in: nil), try await store.createTask("归档的", in: nil),
      try await store.createTask("删了的", in: nil), try await store.createTask("项目进回收站的", in: project.id),
      try await store.createTask("还在做的", in: nil),
    ]
    for task in tasks { try await store.addCueMessage(.cue, text: "收下「\(task.body)」？", choices: ["收下", "再改"], task: task.id) }
    try await store.addCueMessage(.cue, text: "要不要升级 Node？", choices: ["要", "不要"])
    #expect(try await store.cueMessagesWaitingForYou().count == 6)

    try await store.setStatus(tasks[0].id, .done)
    try await store.archive(tasks[1].id)
    try await store.trashCard(tasks[2].id)
    try await store.trashProject(project.id)
    #expect(try await store.cueMessagesWaitingForYou().map(\.text) == ["收下「还在做的」？", "要不要升级 Node？"])
  }
}
