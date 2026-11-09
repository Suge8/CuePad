import CueStore
import Foundation
import Testing

@Suite struct PiAlertRuleTests {
  let fixture = try! Fixture()
  let clock = ManualTiming()
  var store: CueStore { fixture.store }

  private func write(_ recorder: PiStateRecorder, _ state: PiWorkState) async throws {
    clock.advance(.seconds(10))
    try await recorder.update(sessionID: "s1", state: state, times: PiTimes(stateSince: clock.now, busySince: nil))
  }

  private func current() async throws -> PiSessionState { try #require(try await store.allPiSessionStates().first) }

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
