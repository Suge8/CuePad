import CueStore
import Foundation
import Testing

/// Pi 会话状态记录（Mac 写，按会话一条）：开始工作、等你确认、完成、出错立即写；工作中的细节变化合并且有最短间隔；
/// 会话结束记为"已结束"并保留近况；历史会话（本机会话文件索引）写成同一种记录，会话文件被删时才删。
@Suite struct PiStateTests {
  let fixture = try! Fixture()
  let clock = ManualTiming()
  var store: CueStore { fixture.store }

  private func recorder(host: String = "mac-a", interval: Duration = .seconds(5)) -> PiStateRecorder {
    PiStateRecorder(store: store, hostID: host, minInterval: interval, timing: clock.timing)
  }

  private func states() async throws -> [String: PiSessionState] {
    Dictionary(uniqueKeysWithValues: try await store.allPiSessionStates().map { ($0.sessionID, $0) })
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
    let merged = try await eventually(store, watching: [.piSessionStates], { try $0.allPiSessionStates() }) { $0.first?.state == .known(.tool) }
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

    let all = try await store.allPiSessionStates()
    #expect(all.count == 2)
    #expect(try await states()["s1"]?.id == id)
    #expect(try RawDB(fixture.url).count("piSessionStates") == 2)
  }

  /// 计时基准由调用方（扩展）给出、原样写入：同一段连续处理里思考与工具切换时两者都不变。
  @Test func timesFromTheCallerAreWrittenAsIs() async throws {
    let recorder = recorder()
    let start = clock.now.addingTimeInterval(-90)
    let times = PiTimes(stateSince: start, busySince: start)
    try await recorder.update(sessionID: "s1", state: .thinking, times: times)
    clock.advance(.seconds(10))
    try await recorder.update(sessionID: "s1", state: .waitingForUser, times: PiTimes(stateSince: clock.now, busySince: start))
    let waiting = try #require(try await states()["s1"])
    #expect(waiting.stateSince == clock.now && waiting.busySince == start)

    clock.advance(.seconds(10))
    try await recorder.update(sessionID: "s1", state: .settled, times: PiTimes(stateSince: clock.now, busySince: nil))
    let idle = try #require(try await states()["s1"])
    #expect(idle.stateSince == clock.now && idle.busySince == nil)
  }

  /// 等你回答的弹窗立即写、答完写回 nil；摘要不归记录器写（是对话的投影），状态变化不改它。
  @Test func questionChangesAreWrittenImmediatelyAndTheRecapIsLeftToTheTranscript() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "s1", state: .thinking)
    try await store.writePiTranscript(PiTranscript(sessionID: "s1", messages: [], recap: PiRecap(lastPrompt: "修好登录", lastReply: "好的")))

    let question = PiQuestion(promptID: "p-1", kind: .select, text: "覆盖？", options: ["是", "否"])
    try await recorder.update(sessionID: "s1", state: .waitingForUser, question: question)
    #expect(try await states()["s1"]?.question == question)
    try await recorder.update(sessionID: "s1", state: .thinking)
    let written = try #require(try await states()["s1"])
    #expect(written.question == nil && written.lastPrompt == "修好登录" && written.lastReply == "好的")
  }

  @Test func endingASessionKeepsItsRecordAsEndedWithItsRecapAndDropsPendingUpdates() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "s1", state: .thinking)
    try await store.writePiTranscript(PiTranscript(sessionID: "s1", messages: [], recap: PiRecap(lastPrompt: "跑测试", lastReply: "全部通过")))
    try await recorder.update(sessionID: "s1", state: .tool, detail: "pending")
    await clock.waitForSleeper()

    try await recorder.end(sessionID: "s1")
    let ended = try #require(try await states()["s1"])
    #expect(ended.state == .known(.ended) && ended.lastReply == "全部通过" && ended.lastPrompt == "跑测试" && ended.notify == nil)

    clock.advance(.seconds(30))  // 到点也不会把挂起的更新写回来
    await Task.yield()
    #expect(try await states()["s1"]?.state == .known(.ended))
  }

  @Test func endedRecordsAreKept() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "old", state: .settled)
    try await recorder.end(sessionID: "old")
    clock.advance(.seconds(90 * 24 * 3600))

    try await recorder.update(sessionID: "new", state: .settled)
    try await recorder.end(sessionID: "new")

    #expect(Set(try await store.allPiSessionStates().map(\.sessionID)) == ["old", "new"])
  }

  // MARK: 历史会话

  private func indexed(_ id: String, title: String = "修好登录", cwd: String = "/work/app", at seconds: TimeInterval = 1_000) -> PiSession {
    PiSession(id: id, path: "/sessions/--work-app--/\(id).jsonl", cwd: cwd, title: title, lastActivityAt: Date(timeIntervalSince1970: seconds))
  }

  @Test func anIndexedSessionIsAnEndedSyncRecordKeyedByItsSessionID() async throws {
    let project = try await store.createProject(name: "App", color: "#111")
    try await store.setDirectory("/work", for: project.id)

    try await store.upsertPiSession(indexed("s1"), host: "mac-a")

    let state = try #require(try await states()["s1"])
    #expect(state.id == PiSessionState.recordID(sessionID: "s1") && state.state == .known(.ended) && state.hostID == "mac-a")
    #expect(state.title == "修好登录" && state.folder == "app" && state.projectID == project.id)
    #expect(state.stateSince == Date(timeIntervalSince1970: 1_000))
  }

  /// 同一个会话（Pi 重启、恢复后会话 id 不变）始终是同一条记录：在线时由状态写入方负责，索引不覆盖；结束后仍是它。
  @Test func aSessionIsOneRecordAcrossHistoryRestartAndEnd() async throws {
    let recorder = recorder()
    try await store.upsertPiSession(indexed("s1"), host: "mac-a")
    try await recorder.update(sessionID: "s1", state: .thinking, title: "修好登录")
    try await store.upsertPiSession(indexed("s1", title: "改了名", at: 2_000), host: "mac-a")
    #expect(try await states()["s1"]?.state == .known(.thinking))

    try await recorder.end(sessionID: "s1")
    #expect(try await store.allPiSessionStates().count == 1)
    #expect(try await states()["s1"]?.state == .known(.ended))
  }

  /// 索引内容没变时不改记录（不然每次启动都会把几千条历史重新上传）。
  @Test func reindexingAnUnchangedSessionDoesNotTouchItsRecord() async throws {
    try await store.upsertPiSession(indexed("s1"), host: "mac-a")
    let first = try #require(try await states()["s1"]).modifiedAt
    try await Task.sleep(for: .milliseconds(5))
    try await store.upsertPiSession(indexed("s1"), host: "mac-a")
    #expect(try await states()["s1"]?.modifiedAt == first)
  }

  /// 升级前已建过索引的会话没有同步记录（那时还不写）：扫描完成时补写，不受"内容没变不写"影响。
  @Test func indexedSessionsWithoutARecordGetOneWhenScanningFinishes() async throws {
    try await store.upsertPiSession(indexed("s1"), host: "mac-a")
    try await store.upsertPiSession(indexed("s2", title: "第二个"), host: "mac-a")
    try RawDB(fixture.url).exec("DELETE FROM piSessionStates")

    try await store.retainPiSessions(paths: [indexed("s1").path, indexed("s2").path], host: "mac-a")

    #expect(Set(try await store.allPiSessionStates().map(\.sessionID)) == ["s1", "s2"])
    #expect(try await states()["s2"]?.title == "第二个")
  }

  // MARK: 列表查询

  @Test func scopesReturnOnlyTheirStatesAndATokenOrIDPicksOne() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "live", state: .thinking, launchToken: "tok-1")
    try await store.upsertPiSession(indexed("old"), host: "mac-a")
    let project = try await store.createProject(name: "App", color: "#111")
    try await recorder.update(sessionID: "here", state: .settled, projectID: project.id)

    func ids(_ query: PiSessionQuery) async throws -> Set<String> {
      Set(try await store.piSessionPage(query).items.map(\.state.sessionID))
    }
    #expect(try await ids(PiSessionQuery(scope: .live)) == ["live", "here"])
    #expect(try await ids(PiSessionQuery(scope: .ended)) == ["old"])
    #expect(try await ids(PiSessionQuery(scope: .all)) == ["live", "here", "old"])
    #expect(try await ids(PiSessionQuery(project: project.id)) == ["here"])
    #expect(try await ids(PiSessionQuery(launchToken: "tok-1")) == ["live"])
    #expect(try await ids(PiSessionQuery(id: PiSessionState.recordID(sessionID: "old"))) == ["old"])
    #expect(try await store.piSessionPage(PiSessionQuery(scope: .live)).total == 2)
  }

  // MARK: 目录绑定

  /// 项目在哪台 Mac 上绑定了目录：只带目录末段名，不同步完整路径；只管这台 Mac 自己的，别的 Mac 的不动。
  @Test func directoryBindingsFollowThisMacsDirectoriesWithTheFolderNameOnly() async throws {
    let app = try await store.createProject(name: "App", color: "#111")
    let site = try await store.createProject(name: "Site", color: "#222")
    try await store.setDirectory("/Users/someone/work/app", for: app.id)
    try await store.setDirectory("/Users/someone/work/site", for: site.id)
    try await store.publishDirectoryBindings(host: "mac-b", hostName: "Other")

    try await store.publishDirectoryBindings(host: "mac-a", hostName: "Studio")
    let bindings = try await store.directoryBindings().filter { $0.hostID == "mac-a" }
    #expect(Set(bindings.map(\.folder)) == ["app", "site"] && bindings.allSatisfy { $0.hostName == "Studio" })
    let stored = try RawDB(fixture.url).rows("SELECT * FROM directoryBindings")
    #expect(!stored.flatMap { $0 }.contains { $0.contains("/Users/someone") })

    try await store.setDirectory(nil, for: site.id)
    try await store.publishDirectoryBindings(host: "mac-a", hostName: "Studio")
    #expect(try await store.directoryBindings().filter { $0.hostID == "mac-a" }.map(\.projectID) == [app.id])
    #expect(try await store.directoryBindings().filter { $0.hostID == "mac-b" }.count == 2)
  }

  @Test func recordsOfDeletedSessionFilesAreDeleted() async throws {
    try await store.upsertPiSession(indexed("s1"), host: "mac-a")
    try await store.upsertPiSession(indexed("s2"), host: "mac-a")

    try await store.retainPiSessions(paths: [indexed("s1").path], host: "mac-a")

    #expect(try await store.allPiSessionStates().map(\.sessionID) == ["s1"])
  }

  @Test func resetEndsOnlyThisHostsLeftoverRecords() async throws {
    let mine = recorder(host: "mac-a")
    let other = recorder(host: "mac-b")
    try await mine.update(sessionID: "s1", state: .thinking)
    try await store.writePiTranscript(PiTranscript(sessionID: "s1", messages: [], recap: PiRecap(lastPrompt: "上次的")))
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

  /// 置位的那次写入把标志交还调用方：Mac 据此立即上传这一条，不等引擎几十秒后的自动调度。
  @Test func theWriteThatFlagsReportsTheAlert() async throws {
    let recorder = recorder()
    #expect(try await recorder.update(sessionID: "s1", state: .thinking) == nil)
    #expect(try await recorder.update(sessionID: "s1", state: .tool, detail: "bash") == nil)  // 合并挂起
    #expect(try await recorder.update(sessionID: "s1", state: .settled) == .settled)
    #expect(try await recorder.update(sessionID: "s1", state: .settled, detail: nil, title: "改名") == nil)  // 同状态的后续写入不再报告
    #expect(try await recorder.update(sessionID: "s1", state: .waitingForUser) == .waitingForUser)
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
