import CueStore
import Foundation
import Testing

@Suite struct CueWorkTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  @Test func aTaskWithStepsCompletesOnlyWhenEveryStepIsDone() async throws {
    let task = try await store.createTask("发布")
    let steps = [try await store.createTask("改脚本", under: task.id), try await store.createTask("跑检查", under: task.id)]
    let other = try await store.createTask("写周报")
    let recorder = PiStateRecorder(store: store, hostID: "mac")
    for (step, session) in zip(steps, ["s1", "s2"]) {
      let launch = try await store.requestLaunch(PiLaunch(project: step.projectID, prompt: step.body, token: session), title: step.heading, on: "mac", card: step.id)
      try await recorder.update(sessionID: session, state: .settled, title: session, launchToken: launch.launch?.token, hosted: true)
    }
    try await store.bindSession("s1", to: other.id)
    try await store.setStatus(steps[0].id, .done)
    await #expect(throws: CueStoreError.stepsRemaining(1)) { try await store.finishTask(task.id, evidence: ["脚本改好了"]) }

    try await store.setStatus(steps[1].id, .done)
    let ends = try await store.finishTask(task.id, evidence: ["检查都过了"]).ended
    #expect(try await store.card(task.id)?.status == .done)
    #expect(ends.compactMap(\.target.ref) == ["s2"] && ends.allSatisfy { $0.mode == .known(.end) })
    #expect(try await store.completeTask(other.id).ended.compactMap(\.target.ref) == ["s1"])
  }

  @Test func aSessionBelongsToItsOpenTaskBeforeADoneOne() async throws {
    let open = try await store.createTask("还在做的那件")
    let done = try await store.createTask("做完的那件")
    try await store.linkCard(open.id, toSession: "s1")
    try await store.linkCard(done.id, toSession: "s1")
    try await store.setStatus(done.id, .done)
    let since = CueMarks(try await store.lastWrite())

    try await store.runtimeRecorder(on: "mac").update(sessionID: "s1", state: .waitingForUser, detail: "确认写入？")

    #expect(try await store.cueTally().waiting.map(\.task) == [open.id])
    let changes = try await store.cueChanges(after: since).due.filter { $0.session?.sessionID == "s1" }
    #expect(changes.map(\.kind) == [.waitingForUser])
    #expect(changes.map(\.task?.id) == [open.id] && changes.map(\.leaf?.id) == [open.id])

    try await store.setStatus(open.id, .done)
    #expect(try await store.cueTally().waiting.map(\.task).count == 1, "只剩做完的也归它，照样在等你")
  }
}
