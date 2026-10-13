import CueAgent
import CueStore
import Foundation
import Testing

/// 交给 Cue 的大脑的信封。
@Suite struct EnvelopeTests {
  /// 刚启用的第一次醒来，信封里写明原因。
  @Test func theFirstWakeAfterEnablingSaysSo() {
    let text = CueEnvelope.render(.init(
      now: .now, contextUsed: nil, renewAt: 150_000, since: .now, changes: [], board: [], waiting: [], wake: .enabled, said: nil))
    #expect(text.split(separator: "\n").contains("醒来：刚启用"))
  }
}
