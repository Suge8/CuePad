import CueStore
import Foundation
import Testing

/// 管理器与界面直接读的几项：待交给大脑的、记忆的版本读数。
@Suite struct CueKitReadsTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  /// 待交给大脑的：你说了没交的话、"等你"上没交的回答；交过的不再交。
  @Test func whatIsLeftToDeliverToTheBrain() async throws {
    let said = try await store.addCueMessage(.you, text: "看看发布")
    let asked = try await store.addCueMessage(.cue, text: "合并吗？", ask: .merge)
    try await store.addCueMessage(.cue, text: "开工了")
    #expect(try await store.cueMessagesToDeliver().map(\.id) == [said.id])

    try await store.endCueQuestion(asked.id, .answered(CueAsk.once))
    #expect(try await store.cueMessagesToDeliver().map(\.id) == [said.id, asked.id])
    try await store.markCueMessagesDelivered([said.id, asked.id])
    #expect(try await store.cueMessagesToDeliver().isEmpty)
  }

  /// 记忆的版本读数随记、忘、写摘要而变。
  @Test func memoryVersionMovesWithEveryChange() async throws {
    var seen = [try await store.cueMemoryVersion()]
    for index in 0..<2 { try await store.noteCueLine("第 \(index) 条", source: .cue) }
    seen.append(try await store.cueMemoryVersion())
    try await Task.sleep(for: .milliseconds(2))
    try await store.forgetCueLine(try #require(try await store.cueLine(at: 0)).id)
    seen.append(try await store.cueMemoryVersion())
    try await store.setCueSummary(lo: 0, hi: 2, text: "两条")
    seen.append(try await store.cueMemoryVersion())
    #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 != $1 })
  }
}
