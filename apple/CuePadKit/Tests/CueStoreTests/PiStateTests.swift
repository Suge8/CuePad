import CueStore
import Foundation
import Testing

/// Pi 会话状态记录（Mac 写，按会话一条）：等你确认、完成、出错与开始工作立即写，不受细节节流；同一个会话只有一条记录；手机通知标志。
/// 各字段写进同步记录、结束后保留、启动对账只动本机的见 App 的 MacSyncTests。
@Suite struct PiStateTests {
  let fixture = try! Fixture()
  let clock = ManualTiming()
  var store: CueStore { fixture.store }

  private func recorder() -> PiStateRecorder { PiStateRecorder(store: store, hostID: "mac-a", timing: clock.timing) }

  private func states() async throws -> [String: PiSessionState] {
    Dictionary(uniqueKeysWithValues: try await store.allPiSessionStates().map { ($0.sessionID, $0) })
  }

  /// 合并定时器到点的同时来了一次立即写入（完成）：挂起的旧细节不能在更新的状态之后落盘，
  /// 否则手机上的会话会一直显示"工作中"。
  @Test
  func pendingDetailFiringAlongsideANewerStateNeverOverwritesIt() async throws {
    let recorder = recorder()
    for round in 0..<40 {
      let id = "s\(round)"
      try await recorder.update(sessionID: id, state: .thinking)
      try await recorder.update(sessionID: id, state: .tool, detail: "stale")
      await clock.waitForSleeper()
      clock.advance(PiStateRecorder.detailInterval)
      try await recorder.update(sessionID: id, state: .settled)
      try await recorder.update(sessionID: id, state: .settled)
      #expect(try await states()[id]?.state == .known(.settled), "第 \(round) 轮")
    }
  }

  /// 工作中的细节按 `detailInterval` 节流：等你、出错、做完与再开始工作都不等它，立即写，并取代挂起的细节。
  @Test func stateTransitionsAreWrittenImmediatelyDespiteTheDetailInterval() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "s1", state: .thinking)
    try await recorder.update(sessionID: "s1", state: .tool, detail: "pending")  // 挂起中
    #expect(try await states()["s1"]?.state == .known(.thinking))

    try await recorder.update(sessionID: "s1", state: .waitingForUser, detail: "确认写入文件？")
    #expect(try await states()["s1"]?.state == .known(.waitingForUser))
    try await recorder.update(sessionID: "s1", state: .error, detail: "boom")
    #expect(try await states()["s1"]?.state == .known(.error))
    try await recorder.update(sessionID: "s1", state: .settled)
    let settled = try await states()["s1"]
    #expect(settled?.state == .known(.settled) && settled?.detail == nil)
    try await recorder.update(sessionID: "s1", state: .thinking)  // 下一轮开始工作
    #expect(try await states()["s1"]?.state == .known(.thinking))
    try await recorder.update(sessionID: "s1", state: .settled)  // 一转眼又做完
    #expect(try await states()["s1"]?.state == .known(.settled))
  }

  // MARK: 历史会话

  private func indexed(_ id: String, title: String = "修好登录", cwd: String = "/work/app", at seconds: TimeInterval = 1_000) -> IndexedSession {
    IndexedSession(id: id, path: "/sessions/--work-app--/\(id).jsonl", cwd: cwd, title: title, lastActivityAt: Date(timeIntervalSince1970: seconds))
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

  /// App 重开：进程随上次退出了的托管会话原本出错的，仍是出错、原因与起点留着。
  @Test func aHostedErrorStaysAcrossARestart() async throws {
    let before = clock.now
    try await recorder().update(
      sessionID: "failed", state: .error, detail: "额度用完", times: PiTimes(stateSince: before, busySince: nil), hosted: true,
      process: PiProcess(pid: 1, startedAt: 1))
    clock.advance(.seconds(60))

    try await recorder().reset { _ in false }

    let failed = try await states()["failed"]
    #expect(failed?.state == .known(.error) && failed?.detail == "额度用完" && failed?.stateSince == before)
  }

  // MARK: 手机通知标志：只在"进入等你确认"和"从工作中进入完成"的那一次写入置位

  private func alert(_ sessionID: String = "s1") async throws -> Open<PiAlert>? {
    try await states()[sessionID]?.notify
  }

  /// 第一次看到的会话不置位：App 重开后不把旧的等你、做完再报一遍。
  @Test func enteringWaitingForUserFlagsTheWriteThatEntersItAndSurvivesSameStateUpdatesUntilUploaded() async throws {
    let recorder = recorder()
    try await recorder.update(sessionID: "first-seen", state: .waitingForUser)
    #expect(try await alert("first-seen") == nil)
    try await recorder.update(sessionID: "s1", state: .thinking)
    #expect(try await alert() == nil)

    try await recorder.update(sessionID: "s1", state: .waitingForUser, detail: "确认写入？")
    #expect(try await alert() == .known(.waitingForUser))

    // 仍在等、只是问题换了：标志还没上传就不能被抹掉（否则用户仍被等着，锁屏却收不到通知）
    try await recorder.update(sessionID: "s1", state: .waitingForUser, detail: "换了个问题")
    #expect(try await alert() == .known(.waitingForUser))
    #expect(try await states()["s1"]?.detail == "换了个问题")
  }
}
