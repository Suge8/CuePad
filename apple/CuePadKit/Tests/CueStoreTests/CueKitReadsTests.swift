import CueStore
import Foundation
import Testing

/// Cue 的记忆跨设备合并：摘要覆盖的行在别处被忘掉，摘要作废。
@Suite struct CueKitReadsTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  /// 别的设备先忘掉一行、本机随后写了覆盖它的摘要、忘掉的同步才到：摘要照样作废。
  @Test func aForgetSyncedAfterTheSummaryStillVoidsIt() async throws {
    for index in 0..<2 { try await store.noteCueLine("第 \(index) 条", source: .cue) }
    try await store.setCueSummary(lo: 0, hi: 2, text: "两条的摘要")
    #expect(try await store.cueMemory().summaries.map(\.text) == ["两条的摘要"])

    let line = try #require(try await store.cueLine(at: 1))
    try RawDB(fixture.url).exec("UPDATE cueLines SET deletedAt = 1 WHERE id = '\(line.id.uuidString.lowercased())'")
    #expect(try await store.cueMemory().summaries.isEmpty)
  }
}
