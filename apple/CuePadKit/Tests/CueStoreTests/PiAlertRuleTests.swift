import CueStore
import CueTestSupport
import Foundation
import Testing

/// 要不要提示（"等你确认"、"做完了"）只有一条规则：Mac 写同步记录时据它置位通知标志，手机在前台读同步来的记录做 App 内提示也用它。
@Suite struct PiAlertRuleTests {
  let fixture = try! Fixture()
  let clock = ManualTiming()
  var store: CueStore { fixture.store }

  private func write(_ recorder: PiStateRecorder, _ state: PiWorkState) async throws {
    clock.advance(.seconds(10))
    try await recorder.update(sessionID: "s1", state: state, times: PiTimes(stateSince: clock.now, busySince: nil))
  }

  private func current() async throws -> PiSessionState { try #require(try await store.allPiSessionStates().first) }

  @Test(arguments: [
    (nil, PiWorkState.settled, nil), (nil, .waitingForUser, nil),  // 第一次看到的会话不提示
    (.thinking, .settled, .settled), (.delegating, .settled, .settled), (.tool, .waitingForUser, .waitingForUser),
    (.waitingForUser, .waitingForUser, nil), (.waitingForUser, .settled, nil), (.error, .settled, nil),
    (.thinking, .thinking, nil), (.settled, .thinking, nil), (.settled, .error, nil),
  ] as [(PiWorkState?, PiWorkState, PiAlert?)])
  func transitionsThatAlert(from previous: PiWorkState?, to state: PiWorkState, expected: PiAlert?) {
    #expect(PiAlert.entering(state, from: previous) == expected)
  }

  /// 手机读到的是同步合并后的版本：上一轮的"完成"之后直接是下一轮的"完成"，中间的"工作中"没读到——
  /// 状态没变而状态起点往后走了，就是又做完了一轮。
  @Test func aRoundFinishedBetweenTwoReadsIsStillRecognised() async throws {
    let recorder = PiStateRecorder(store: store, hostID: "mac", timing: clock.timing)
    try await write(recorder, .thinking)
    try await write(recorder, .settled)
    let seen = try await current()

    try await write(recorder, .thinking)
    try await write(recorder, .settled)
    let now = try await current()

    #expect(now.alert(since: seen) == .settled)
    #expect(now.alert(since: now) == nil)  // 同一版本读两遍不重复提示
    #expect(seen.alert(since: nil) == nil)
  }

  @Test func renamingASettledSessionDoesNotAlertAgain() async throws {
    let recorder = PiStateRecorder(store: store, hostID: "mac", timing: clock.timing)
    try await write(recorder, .thinking)
    try await write(recorder, .settled)
    let seen = try await current()

    try await recorder.update(sessionID: "s1", state: .settled, title: "新名字", times: PiTimes(stateSince: seen.stateSince, busySince: nil))

    #expect(try await current().alert(since: seen) == nil)
  }

  @Test func enteringTheWaitingStateAlertsWhetherOrNotTheWorkingStateWasRead() async throws {
    let recorder = PiStateRecorder(store: store, hostID: "mac", timing: clock.timing)
    try await write(recorder, .thinking)
    let working = try await current()
    try await write(recorder, .waitingForUser)
    #expect(try await current().alert(since: working) == .waitingForUser)
  }
}
