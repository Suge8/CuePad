import CueStore
import Foundation
import Testing

@Suite struct CueMemoryTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  @Test func aForgetSyncedAfterTheSummaryStillVoidsIt() async throws {
    for index in 0..<2 { try await store.noteCueLine("第 \(index) 条", source: .cue) }
    let memory = try await store.cueMemory()
    try await store.setCueSummary(range: #require(memory.range(lo: 0, hi: 2)), text: "两条的摘要")
    #expect(try await store.cueMemory().summaries.map(\.text) == ["两条的摘要"])

    let line = memory.lines[1]
    try RawDB(fixture.url).exec("UPDATE cueLines SET deletedAt = 1 WHERE id = '\(line.id.uuidString.lowercased())'")
    #expect(try await store.cueMemory().summaries.isEmpty)
  }
}
