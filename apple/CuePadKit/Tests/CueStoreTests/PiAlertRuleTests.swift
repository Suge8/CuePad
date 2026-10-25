import CueStore
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
    (.thinking, .settled, .settled), (.delegating, .settled, .settled), (.compacting, .settled, .settled), (.tool, .waitingForUser, .waitingForUser),
    (.waitingForUser, .waitingForUser, nil), (.waitingForUser, .settled, nil), (.error, .settled, nil),
    (.thinking, .thinking, nil), (.settled, .thinking, nil), (.settled, .error, nil),
  ] as [(PiWorkState?, PiWorkState, PiAlert?)])
  func transitionsThatAlert(from previous: PiWorkState?, to state: PiWorkState, expected: PiAlert?) {
    let then = Date(timeIntervalSince1970: 100)
    #expect(PiAlert.entering(state, since: then.addingTimeInterval(10), from: previous.map { ($0, then) }) == expected)
  }

  /// 歇着时的手动压缩：扩展先报"在压缩"，压完（或失败、被停止）回到原来的"做完了"与原来的起点——这不是又做完了一轮，
  /// Mac 不置位通知标志，手机不论读没读到"在压缩"那一版都不提示；压缩发生在一轮里时，压完歇下照常是"做完了"。
  @Test func compactingWhileSettledAndFallingBackIsNotANewRound() async throws {
    let recorder = PiStateRecorder(store: store, hostID: "mac", timing: clock.timing)
    try await write(recorder, .thinking)
    try await write(recorder, .settled)
    let settled = try await current()

    try await write(recorder, .compacting)
    let compacting = try await current()
    clock.advance(.seconds(10))
    let alert = try await recorder.update(sessionID: "s1", state: .settled, times: PiTimes(stateSince: settled.stateSince, busySince: nil))
    let back = try await current()

    #expect(alert == nil && back.notify == nil)
    #expect(back.alert(since: compacting) == nil && back.alert(since: settled) == nil)

    try await write(recorder, .compacting)  // 一轮里的压缩：压完歇下是新的起点
    try await write(recorder, .settled)
    #expect(try await current().alert(since: back) == .settled)
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
}
