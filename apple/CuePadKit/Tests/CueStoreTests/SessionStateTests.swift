import CueStore
import Foundation
import Testing

@Suite struct SessionStateTests {
  let fixture = try! Fixture()
  let clock = ManualTiming()
  var store: CueStore { fixture.store }

  private func recorder() -> StateRecorder { StateRecorder(store: store, hostID: "mac-a", timing: clock.timing) }

  private func states() async throws -> [String: SessionState] {
    Dictionary(uniqueKeysWithValues: try await store.allSessionStates().map { ($0.sessionID, $0) })
  }

  @Test
  func pendingDetailFiringAlongsideANewerStateNeverOverwritesIt() async throws {
    let recorder = recorder()
    for round in 0..<40 {
      let id = "s\(round)"
      try await recorder.update(sessionID: id, state: .thinking)
      try await recorder.update(sessionID: id, state: .tool, detail: "stale")
      try await clock.waitForSleeper()
      clock.advance(StateRecorder.detailInterval)
      try await recorder.update(sessionID: id, state: .settled)
      try await recorder.update(sessionID: id, state: .settled)
      #expect(try await states()[id]?.state == .known(.settled), "第 \(round) 轮")
    }
  }

  @Test func stateTransitionsAreWrittenImmediatelyDespiteTheDetailInterval() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "s1", state: .thinking)
    try await recorder.update(sessionID: "s1", state: .tool, detail: "pending")
    #expect(try await states()["s1"]?.state == .known(.thinking))

    try await recorder.update(sessionID: "s1", state: .waitingForUser, detail: "确认写入文件？")
    #expect(try await states()["s1"]?.state == .known(.waitingForUser))
    try await recorder.update(sessionID: "s1", state: .error, detail: "boom")
    #expect(try await states()["s1"]?.state == .known(.error))
    try await recorder.update(sessionID: "s1", state: .settled)
    let settled = try await states()["s1"]
    #expect(settled?.state == .known(.settled) && settled?.detail == nil)
    try await recorder.update(sessionID: "s1", state: .thinking)
    #expect(try await states()["s1"]?.state == .known(.thinking))
    try await recorder.update(sessionID: "s1", state: .settled)
    #expect(try await states()["s1"]?.state == .known(.settled))
  }

  // MARK: 历史会话

  private func indexed(_ id: String, title: String = "修好登录", cwd: String = "/work/app", at seconds: TimeInterval = 1_000) -> IndexedSession {
    IndexedSession(id: id, path: "/sessions/--work-app--/\(id).jsonl", cwd: cwd, title: title, lastActivityAt: Date(timeIntervalSince1970: seconds))
  }

  @Test func aSessionIsOneRecordAcrossHistoryRestartAndEnd() async throws {
    let recorder = recorder()
    try await store.upsertSession(indexed("s1"), host: "mac-a")
    try await recorder.update(sessionID: "s1", state: .thinking, title: "修好登录")
    try await store.upsertSession(indexed("s1", title: "改了名", at: 2_000), host: "mac-a")
    #expect(try await states()["s1"]?.state == .known(.thinking))

    try await recorder.end(sessionID: "s1")
    #expect(try await store.allSessionStates().count == 1)
    #expect(try await states()["s1"]?.state == .known(.ended))
  }

  @Test func aHostedErrorStaysAcrossARestart() async throws {
    let before = clock.now
    try await recorder().update(
      sessionID: "failed", state: .error, detail: "额度用完", times: SessionTimes(stateSince: before, busySince: nil), hosted: true,
      process: SessionProcess(pid: 1, startedAt: 1))
    clock.advance(.seconds(60))

    _ = try store.launchMac(host: "mac-a") { _ in false }

    let failed = try await states()["failed"]
    #expect(failed?.state == .known(.error) && failed?.detail == "额度用完" && failed?.stateSince == before)
  }

  // MARK: 手机通知标志

  private func alert(_ sessionID: String = "s1") async throws -> AlertPush? {
    try await states()[sessionID]?.notify
  }

  @Test func enteringWaitingForUserFlagsTheWriteThatEntersItAndSurvivesSameStateUpdatesUntilUploaded() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "first-seen", state: .waitingForUser)
    #expect(try await alert("first-seen") == nil)
    try await recorder.update(sessionID: "s1", state: .thinking)
    #expect(try await alert() == nil)

    try await recorder.update(sessionID: "s1", state: .waitingForUser, detail: "确认写入？")
    #expect(try await alert() == .alert(.waitingForUser))

    try await recorder.update(sessionID: "s1", state: .waitingForUser, detail: "换了个问题")
    #expect(try await alert() == .alert(.waitingForUser))
    #expect(try await states()["s1"]?.detail == "换了个问题")
  }
}
