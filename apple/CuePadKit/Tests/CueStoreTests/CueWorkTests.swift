import CueStore
import Foundation
import Testing

/// Cue 收尾一件事、它醒来看到的变化、"等你"由事实推出。
@Suite struct CueWorkTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  /// Cue 收尾整件事：还有步骤没做完时不行（说还剩几个）；步骤都做完了，任务完成，各步骤上的会话请它结束——
  /// 只结束绑着的事都做完了的：一个会话还绑着别的没做完的事就留着，那件事完成（你点圆圈也一样）时才结束。
  @Test func aTaskWithStepsCompletesOnlyWhenEveryStepIsDone() async throws {
    let task = try await store.createTask("发布")
    let steps = [try await store.createTask("改脚本", under: task.id), try await store.createTask("跑检查", under: task.id)]
    let other = try await store.createTask("写周报")
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

  /// 会话归哪件事只有一条规则：绑着它的任务里最近修改的那件，做完了的也算（问题没答就还是在等你）。
  /// 等你落在哪件事上与报给 Cue 的变化归到同一件，一个会话只报一次。
  @Test func aSessionBoundToSeveralTasksBelongsToTheLatestOneEvenWhenItIsDone() async throws {
    let older = try await store.createTask("旧的那件")
    let latest = try await store.createTask("新的那件")
    try await store.linkCard(older.id, toSession: "s1")
    try await store.linkCard(latest.id, toSession: "s1")
    try await store.setStatus(latest.id, .done)
    try RawDB(fixture.url).exec("UPDATE cards SET modifiedAt = 1 WHERE id = '\(older.id.uuidString.lowercased())'")
    let since = CueMarks(try await store.lastWrite())

    try await PiStateRecorder(store: store, hostID: "mac").update(sessionID: "s1", state: .waitingForUser, detail: "确认写入？")

    #expect(try await store.cueTally().waiting.map(\.task) == [latest.id])
    let changes = try await store.cueChanges(after: since).due.filter { $0.session?.sessionID == "s1" }
    #expect(changes.map(\.kind) == [.waitingForUser])
    #expect(changes.map(\.task?.id) == [latest.id] && changes.map(\.leaf?.id) == [latest.id])
  }
}
