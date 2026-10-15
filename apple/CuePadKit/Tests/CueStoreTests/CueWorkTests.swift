import CueStore
import Foundation
import Testing

/// Cue 收尾一件事、它醒来看到的变化、"等你"由事实推出。
@Suite struct CueWorkTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  /// Cue 请会话停下没能做到（会话所在的 Mac 报错）：是一条变化，带上动作与原因；完成的请求过了保留期就清理，它也还在，
  /// Cue 醒来时一定看得到。你自己发起的请求失败了不报（界面上看得见）。
  @Test func aFailedRequestFromCueIsAChangeThatOutlivesCleanup() async throws {
    let task = try await store.createTask("发布", in: nil)
    try await store.linkCard(task.id, toSession: "s1")
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
    #expect(changes.first?.task.id == task.id && changes.first?.leaf?.id == task.id)
  }

  /// Cue 收尾整件事：还有步骤没做完时不行（说还剩几个）；步骤都做完了，任务完成，各步骤上的会话请它结束——
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
    await #expect(throws: CueStoreError.stepsRemaining(1)) { try await store.finishTask(task.id, evidence: ["脚本改好了"]) }

    try await store.setStatus(steps[1].id, .done)
    let ends = try await store.finishTask(task.id, evidence: ["检查都过了"]).ended
    #expect(try await store.card(task.id)?.status == .done)
    #expect(ends.compactMap(\.target.ref) == ["s2"] && ends.allSatisfy { $0.mode == .known(.end) })
    #expect(try await store.toggleDone(other.id).ended.compactMap(\.target.ref) == ["s1"])
  }
}
