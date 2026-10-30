import CueAgent
import CueStore
import CueTestSupport
import Testing

/// 记忆视图（OptMem 的读法）：Cue 按"待合并"把块一次写成摘要之后，视图的行数固定在预算内，一直记着的全列、最新的原样。
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

    for merge in view.merges { try await store.setCueSummary(lo: merge.lo, hi: merge.hi, text: "#\(merge.lo)-\(merge.hi - 1) 的摘要") }
    view = CueMemoryView(try await store.cueMemory())

    #expect(view.merges.isEmpty)
    #expect(view.pinned.map(\.line.text) == ["第 5 条"])
    #expect(view.entries.count == CueMemoryView.budget - 1)
    #expect(try #require(view.viewText).split(separator: "\n").dropLast().last?.hasSuffix(" 第 \(total - 1) 条") == true)
    #expect(!view.pinnedOverBudget)

    // 忘掉一条：覆盖它的摘要作废，它所在的块重新拆开、等待合并
    let forgotten = try #require(try await store.cueLine(at: 1))
    try await store.forgetCueLine(forgotten.id)
    let after = CueMemoryView(try await store.cueMemory())
    #expect(!after.merges.isEmpty)
    #expect(try #require(after.viewText).split(separator: "\n").allSatisfy { !$0.hasPrefix("#1 ") })
  }

  /// 一直记着的越堆越多：新钉了 5 条就交给后台整理；整理的大脑把同一件事的几条并成一条（有他的原话就算他的）、把一次性的放回普通记忆，
  /// 只动一直记着的；整理过的那组没变就不再交。
  @Test func theDreamTidiesWhatIsAlwaysKept() async throws {
    let rules: [(String, CueLineSource)] = [
      ("回复要短", .you), ("回复先说结论", .cue), ("以后推送都不用问", .you), ("这周在修登录页", .cue), ("提交信息用中文", .you),
    ]
    for (text, source) in rules {
      try await store.noteCueLine(text, source: source, pinned: true)
      try await Task.sleep(for: .milliseconds(2))
    }
    try await store.noteCueLine("周会在周一", source: .cue)
    var view = CueMemoryView(try await store.cueMemory())
    #expect(view.tidyDue(since: []))
    #expect(try #require(view.dreamText(tidy: true)).contains("<pinned>"))

    let dream = CueTools(store: store, toolset: .dream)
    let merged = try #require(await dream.call("tidy", ["lines": [0, 1], "text": "回复要短，先说结论"]))
    #expect(!merged.isError && merged.text.contains("#6"))
    #expect(try #require(await dream.call("tidy", ["lines": [3]])).isError == false)
    #expect(try #require(await dream.call("tidy", ["lines": [5], "text": "周会"])).isError)

    view = CueMemoryView(try await store.cueMemory())
    #expect(view.pinned.map(\.line.text) == ["以后推送都不用问", "提交信息用中文", "回复要短，先说结论"])
    #expect(view.pinned.last?.line.source == .known(.you))
    #expect(try await store.recentCueMemory().lines.contains { $0.text == "这周在修登录页" && !$0.pinned })
    #expect(!view.tidyDue(since: Set(view.pinned.map(\.line.id))))
  }

  /// 一直记着的超过硬线：系统提示里写出用量并叫 Cue 合并。
  @Test func pinnedPastTheHardLineAsksCueToMerge() async throws {
    let text = String(repeating: "规", count: CueMemoryLine.maxBytes / 3)
    for _ in 0...(CueMemoryLine.pinnedHard / text.utf8.count) { try await store.noteCueLine(text, source: .you, pinned: true) }
    let view = CueMemoryView(try await store.cueMemory())
    #expect(view.pinnedText.hasPrefix("\(view.pinned.count) 条，8.2KB / 8KB：超了"))
    #expect(view.pinnedText.contains("note replaces"))
  }
}
