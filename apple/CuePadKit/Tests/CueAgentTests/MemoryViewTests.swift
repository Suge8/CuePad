import CueAgent
import CueStore
import CueTestSupport
import Foundation
import Testing

/// 记忆视图（OptMem 的读法）：Cue 按"待合并"把块写成摘要之后，视图的行数固定在预算内，一直记着的全列、最新的原样。
@Suite struct MemoryViewTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  @Test func mergingWhatTheViewAsksForKeepsItWithinBudget() async throws {
    let total = CueMemoryView.budget + 34
    for index in 0..<total {
      try await store.noteCueLine("第 \(index) 条", source: .cue, pinned: index == 5)
      try await Task.sleep(for: .milliseconds(2))  // 序号按记下的先后
    }
    var view = CueMemoryView(try await store.cueMemory())
    #expect(!view.merges.isEmpty)

    for _ in 0..<10 where !view.merges.isEmpty {
      for merge in view.merges { try await store.setCueSummary(lo: merge.lo, hi: merge.hi, text: "#\(merge.lo)-\(merge.hi - 1) 的摘要") }
      view = CueMemoryView(try await store.cueMemory())
    }

    #expect(view.merges.isEmpty)
    #expect(view.pinned.map(\.line.text) == ["第 5 条"])
    #expect(view.entries.count == CueMemoryView.budget - 1)
    #expect(view.entries.last == .line(index: total - 1, text: "第 \(total - 1) 条"))
    #expect(!view.pinnedOverBudget)

    // 忘掉一条：覆盖它的摘要作废，它所在的块重新拆开、等待合并
    let forgotten = try #require(try await store.cueLine(at: 1))
    try await store.forgetCueLine(forgotten.id)
    let after = CueMemoryView(try await store.cueMemory())
    #expect(!after.merges.isEmpty)
    #expect(!after.entries.contains(.line(index: 1, text: "第 1 条")))
  }

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
