import CueStore
import Foundation
import Testing

/// Pi 会话状态记录（Mac 写，按会话一条）：开始工作、等你确认、完成、出错立即写；工作中的细节变化合并且有最短间隔；会话结束删除。
@Suite struct PiStateTests {
  let fixture = try! Fixture()
  let clock = ManualTiming()
  var store: CueStore { fixture.store }

  private func recorder(host: String = "mac-a", interval: Duration = .seconds(5)) -> PiStateRecorder {
    PiStateRecorder(store: store, hostID: host, minInterval: interval, timing: clock.timing)
  }

  private func states() async throws -> [String: PiSessionState] {
    Dictionary(uniqueKeysWithValues: try await store.piSessionStates().map { ($0.sessionID, $0) })
  }

  @Test func startingWorkIsWrittenImmediatelyWithTitleAndProject() async throws {
    let project = try await store.createProject(name: "P", color: "#111")
    let recorder = recorder()

    try await recorder.update(sessionID: "s1", state: .thinking, title: "fix the bug", projectID: project.id)

    let state = try #require(try await states()["s1"])
    #expect(state.state == .thinking && state.title == "fix the bug" && state.projectID == project.id && state.hostID == "mac-a")
    #expect(state.stateSince == clock.now)
  }

  @Test(.timeLimit(.minutes(1)))
  func detailChangesWhileWorkingAreMergedAndWrittenOnceAfterTheMinimumInterval() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "s1", state: .thinking)
    let firstWrite = try #require(try await states()["s1"]).modifiedAt

    try await recorder.update(sessionID: "s1", state: .tool, detail: "bash")
    try await recorder.update(sessionID: "s1", state: .outputting)
    try await recorder.update(sessionID: "s1", state: .tool, detail: "edit")
    #expect(try await states()["s1"]?.state == .thinking)  // 最短间隔内不写
    #expect(try await states()["s1"]?.modifiedAt == firstWrite)

    await clock.waitForSleeper()
    clock.advance(.seconds(5))
    let merged = try await eventually(store, watching: [.piSessionStates], { try $0.piSessionStates() }) { $0.first?.state == .tool }
    #expect(merged.count == 1 && merged[0].detail == "edit")  // 只有最新的一次落盘
  }

  @Test func afterTheIntervalHasPassedWorkingChangesWriteImmediately() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "s1", state: .thinking)
    clock.advance(.seconds(6))
    try await recorder.update(sessionID: "s1", state: .tool, detail: "grep")
    #expect(try await states()["s1"]?.state == .tool)
  }

  @Test func waitingSettledAndErrorAreWrittenImmediatelyAndSupersedeAPendingUpdate() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "s1", state: .thinking)
    try await recorder.update(sessionID: "s1", state: .tool, detail: "pending")  // 挂起中

    try await recorder.update(sessionID: "s1", state: .waitingForUser, detail: "确认写入文件？")
    #expect(try await states()["s1"]?.state == .waitingForUser)
    try await recorder.update(sessionID: "s1", state: .error, detail: "boom")
    #expect(try await states()["s1"]?.state == .error)
    try await recorder.update(sessionID: "s1", state: .settled)
    let settled = try await states()["s1"]
    #expect(settled?.state == .settled && settled?.detail == nil)

    clock.advance(.seconds(30))  // 被取代的挂起更新不会再落盘
    await Task.yield()
    #expect(try await states()["s1"]?.state == .settled)
  }

  @Test func startOfANewWorkRoundIsImmediateEvenInsideTheInterval() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "s1", state: .settled)
    try await recorder.update(sessionID: "s1", state: .thinking)  // 刚完成就又开始工作
    #expect(try await states()["s1"]?.state == .thinking)
  }

  @Test func identicalUpdatesDoNotWriteAgain() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "s1", state: .waitingForUser, detail: "q")
    let first = try #require(try await states()["s1"]).modifiedAt
    clock.advance(.seconds(60))
    try await recorder.update(sessionID: "s1", state: .waitingForUser, detail: "q")
    #expect(try await states()["s1"]?.modifiedAt == first)
  }

  @Test func oneRecordPerSessionWithAStableID() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "s1", state: .thinking)
    let id = try #require(try await states()["s1"]).id
    try await recorder.update(sessionID: "s1", state: .error, detail: "x")
    try await recorder.update(sessionID: "s2", state: .thinking)

    let all = try await store.piSessionStates()
    #expect(all.count == 2)
    #expect(try await states()["s1"]?.id == id)
    #expect(try RawDB(fixture.url).count("piSessionStates") == 2)
  }

  @Test func endingASessionDeletesItsRecordAndDropsPendingUpdates() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "s1", state: .thinking)
    try await recorder.update(sessionID: "s1", state: .tool, detail: "pending")
    await clock.waitForSleeper()

    try await recorder.end(sessionID: "s1")
    #expect(try await store.piSessionStates().isEmpty)

    clock.advance(.seconds(30))  // 到点也不会把已结束的会话写回来
    await Task.yield()
    #expect(try await store.piSessionStates().isEmpty)
  }

  @Test func resetClearsOnlyThisHostsLeftoverRecords() async throws {
    let mine = recorder(host: "mac-a")
    let other = recorder(host: "mac-b")
    try await mine.update(sessionID: "s1", state: .thinking)
    try await other.update(sessionID: "s2", state: .thinking)

    try await mine.reset()

    #expect(try await store.piSessionStates().map(\.sessionID) == ["s2"])
  }

  @Test func unknownStatesFromNewerVersionsAreKept() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "s1", state: .thinking)
    try RawDB(fixture.url).exec("UPDATE piSessionStates SET state = 'compacting'")
    #expect(try await states()["s1"]?.state == .unknown("compacting"))
    #expect(try await states()["s1"]?.state.rawValue == "compacting")
  }

  // MARK: 手机通知标志：只在"进入等你确认"和"从工作中进入完成"的那一次写入置位

  private func alert(_ sessionID: String = "s1") async throws -> PiAlert? {
    try await states()[sessionID]?.notify
  }

  @Test func enteringWaitingForUserFlagsOnlyTheWriteThatEntersIt() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "s1", state: .thinking)
    #expect(try await alert() == nil)

    try await recorder.update(sessionID: "s1", state: .waitingForUser, detail: "确认写入？")
    #expect(try await alert() == .waitingForUser)

    try await recorder.update(sessionID: "s1", state: .waitingForUser, detail: "换了个问题")  // 仍在等：不再通知
    #expect(try await alert() == nil)
  }

  @Test func settledIsFlaggedOnlyWhenComingFromWork() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "s1", state: .thinking)
    try await recorder.update(sessionID: "s1", state: .tool, detail: "bash")  // 合并挂起
    try await recorder.update(sessionID: "s1", state: .settled)  // 从工作中完成（含被合并掉的中间状态）
    #expect(try await alert() == .settled)

    try await recorder.update(sessionID: "s1", state: .thinking)  // 下一轮开始：标志清掉
    #expect(try await alert() == nil)
  }

  @Test func settledAfterWaitingOrErrorIsNotFlagged() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "s1", state: .thinking)
    try await recorder.update(sessionID: "s1", state: .waitingForUser)
    try await recorder.update(sessionID: "s1", state: .settled)  // 不是从工作中来的
    #expect(try await alert() == nil)

    try await recorder.update(sessionID: "s2", state: .thinking)
    try await recorder.update(sessionID: "s2", state: .error, detail: "boom")
    try await recorder.update(sessionID: "s2", state: .settled)
    #expect(try await alert("s2") == nil)
  }

  @Test func errorsAndWorkUpdatesNeverFlag() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "s1", state: .thinking)
    clock.advance(.seconds(6))
    try await recorder.update(sessionID: "s1", state: .outputting)
    #expect(try await alert() == nil)
    try await recorder.update(sessionID: "s1", state: .error, detail: "boom")
    #expect(try await alert() == nil)
  }

  @Test func aSessionSeenForTheFirstTimeNeverFlagsSoRelaunchesDoNotReplayAlerts() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "s1", state: .waitingForUser)
    try await recorder.update(sessionID: "s2", state: .settled)
    #expect(try await alert("s1") == nil)
    #expect(try await alert("s2") == nil)
  }

  @Test func unknownAlertKindsFromNewerVersionsAreKept() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "s1", state: .thinking)
    try RawDB(fixture.url).exec("UPDATE piSessionStates SET notify = 'somethingNew'")
    #expect(try await alert() == .unknown("somethingNew"))
  }
}
