import CueStore
import Foundation
import Testing

/// Pi 会话状态记录（Mac 写，按会话一条）：开始工作、等你确认、完成、出错立即写；工作中的细节变化合并且有最短间隔；
/// 会话结束记为"已结束"并保留近况，过了保留期才删。
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
    #expect(state.state == .known(.thinking) && state.title == "fix the bug" && state.projectID == project.id && state.hostID == "mac-a")
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
    #expect(try await states()["s1"]?.state == .known(.thinking))  // 最短间隔内不写
    #expect(try await states()["s1"]?.modifiedAt == firstWrite)

    await clock.waitForSleeper()
    clock.advance(.seconds(5))
    let merged = try await eventually(store, watching: [.piSessionStates], { try $0.piSessionStates() }) { $0.first?.state == .known(.tool) }
    #expect(merged.count == 1 && merged[0].detail == "edit")  // 只有最新的一次落盘
  }

  /// 合并定时器到点的同时来了一次立即写入（完成）：挂起的旧细节不能在更新的状态之后落盘，
  /// 否则手机上的会话会一直显示"工作中"。
  @Test(.timeLimit(.minutes(1)))
  func pendingDetailFiringAlongsideANewerStateNeverOverwritesIt() async throws {
    let recorder = recorder()
    for round in 0..<40 {
      let id = "s\(round)"
      try await recorder.update(sessionID: id, state: .thinking)
      try await recorder.update(sessionID: id, state: .tool, detail: "stale")
      await clock.waitForSleeper()
      clock.advance(.seconds(5))
      try await recorder.update(sessionID: id, state: .settled)
      try await recorder.update(sessionID: id, state: .settled)
      #expect(try await states()[id]?.state == .known(.settled), "第 \(round) 轮")
    }
  }

  @Test func afterTheIntervalHasPassedWorkingChangesWriteImmediately() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "s1", state: .thinking)
    clock.advance(.seconds(6))
    try await recorder.update(sessionID: "s1", state: .tool, detail: "grep")
    #expect(try await states()["s1"]?.state == .known(.tool))
  }

  @Test func waitingSettledAndErrorAreWrittenImmediatelyAndSupersedeAPendingUpdate() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "s1", state: .thinking)
    try await recorder.update(sessionID: "s1", state: .tool, detail: "pending")  // 挂起中

    try await recorder.update(sessionID: "s1", state: .waitingForUser, detail: "确认写入文件？")
    #expect(try await states()["s1"]?.state == .known(.waitingForUser))
    try await recorder.update(sessionID: "s1", state: .error, detail: "boom")
    #expect(try await states()["s1"]?.state == .known(.error))
    try await recorder.update(sessionID: "s1", state: .settled)
    let settled = try await states()["s1"]
    #expect(settled?.state == .known(.settled) && settled?.detail == nil)

    clock.advance(.seconds(30))  // 被取代的挂起更新不会再落盘
    await Task.yield()
    #expect(try await states()["s1"]?.state == .known(.settled))
  }

  @Test func startOfANewWorkRoundIsImmediateEvenInsideTheInterval() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "s1", state: .settled)
    try await recorder.update(sessionID: "s1", state: .thinking)  // 刚完成就又开始工作
    #expect(try await states()["s1"]?.state == .known(.thinking))
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

  @Test func recapChangesAreWrittenImmediatelyAndAClearedQuestionIsWrittenAsNil() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "s1", state: .thinking, recap: PiRecap(lastPrompt: "修好登录"))
    try await recorder.update(sessionID: "s1", state: .tool, recap: PiRecap(lastPrompt: "修好登录", lastReply: "好的"))
    #expect(try await states()["s1"]?.lastReply == "好的")  // 工作中的合并间隔内，近况变化照样立即写

    try await recorder.update(
      sessionID: "s1", state: .waitingForUser, recap: PiRecap(lastPrompt: "修好登录", lastReply: "好的", question: "覆盖？\n是\n否"))
    #expect(try await states()["s1"]?.question == "覆盖？\n是\n否")
    try await recorder.update(sessionID: "s1", state: .thinking, recap: PiRecap(lastPrompt: "修好登录", lastReply: "好的"))
    let written = try #require(try await states()["s1"])
    #expect(written.question == nil && written.lastPrompt == "修好登录" && written.lastReply == "好的")

    try await recorder.update(sessionID: "s1", state: .settled)  // 不带近况：沿用已有的
    #expect(try await states()["s1"]?.lastReply == "好的")
  }

  @Test func endingASessionKeepsItsRecordAsEndedWithItsRecapAndDropsPendingUpdates() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "s1", state: .thinking, recap: PiRecap(lastPrompt: "跑测试", lastReply: "全部通过"))
    try await recorder.update(sessionID: "s1", state: .tool, detail: "pending")
    await clock.waitForSleeper()

    try await recorder.end(sessionID: "s1")
    let ended = try #require(try await states()["s1"])
    #expect(ended.state == .known(.ended) && ended.lastReply == "全部通过" && ended.lastPrompt == "跑测试" && ended.notify == nil)

    clock.advance(.seconds(30))  // 到点也不会把挂起的更新写回来
    await Task.yield()
    #expect(try await states()["s1"]?.state == .known(.ended))
  }

  @Test func endedRecordsAreDeletedAfterTheRetentionPeriod() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "old", state: .settled)
    try await recorder.end(sessionID: "old")
    clock.advance(PiStateRecorder.endedRetention + .seconds(60))

    try await recorder.update(sessionID: "new", state: .settled)
    try await recorder.end(sessionID: "new")

    #expect(try await store.piSessionStates().map(\.sessionID) == ["new"])
  }

  @Test func resetEndsOnlyThisHostsLeftoverRecords() async throws {
    let mine = recorder(host: "mac-a")
    let other = recorder(host: "mac-b")
    try await mine.update(sessionID: "s1", state: .thinking, recap: PiRecap(lastPrompt: "上次的"))
    try await other.update(sessionID: "s2", state: .thinking)

    try await mine.reset()

    let all = try await states()
    #expect(all["s1"]?.state == .known(.ended) && all["s1"]?.lastPrompt == "上次的")
    #expect(all["s2"]?.state == .known(.thinking))
  }

  @Test func unknownStatesFromNewerVersionsAreKept() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "s1", state: .thinking)
    try RawDB(fixture.url).exec("UPDATE piSessionStates SET state = 'compacting'")
    #expect(try await states()["s1"]?.state == .unknown("compacting"))
    #expect(try await states()["s1"]?.state.rawValue == "compacting")
  }

  // MARK: 手机通知标志：只在"进入等你确认"和"从工作中进入完成"的那一次写入置位

  private func alert(_ sessionID: String = "s1") async throws -> Open<PiAlert>? {
    try await states()[sessionID]?.notify
  }

  @Test func enteringWaitingForUserFlagsTheWriteThatEntersItAndSurvivesSameStateUpdatesUntilUploaded() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "s1", state: .thinking)
    #expect(try await alert() == nil)

    try await recorder.update(sessionID: "s1", state: .waitingForUser, detail: "确认写入？")
    #expect(try await alert() == .known(.waitingForUser))

    // 仍在等、只是问题换了：标志还没上传就不能被抹掉（否则用户仍被等着，锁屏却收不到通知）
    try await recorder.update(sessionID: "s1", state: .waitingForUser, detail: "换了个问题")
    #expect(try await alert() == .known(.waitingForUser))
    #expect(try await states()["s1"]?.detail == "换了个问题")
  }

  @Test func settledIsFlaggedOnlyWhenComingFromWork() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "s1", state: .thinking)
    try await recorder.update(sessionID: "s1", state: .tool, detail: "bash")  // 合并挂起
    try await recorder.update(sessionID: "s1", state: .settled)  // 从工作中完成（含被合并掉的中间状态）
    #expect(try await alert() == .known(.settled))

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
