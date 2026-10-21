#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing

extension MCPTests {
  /// peek 一件事：每个叶子最新的那条回答给全文（至多 4000 字，超了截尾并注明），更早的截短。
  @Test(.timeLimit(.minutes(1))) func peekGivesTheLatestReplyInFull() async throws {
    let sandbox = try Sandbox()
    let store = sandbox.store
    let task = try await store.createTask("跑测试")
    try await store.linkCard(task.id, toSession: "s1")
    try await PiStateRecorder(store: store, hostID: "mac").update(sessionID: "s1", state: .settled, title: "跑测试")
    let older = String(repeating: "旧", count: 500), output = "全部通过 " + String(repeating: "过", count: 4500) + "尾巴"
    try await store.writePiTranscript(PiTranscript(
      sessionID: "s1",
      messages: [
        PiChatMessage(sessionID: "s1", entryID: "1", seq: 1, role: .user, text: "跑一遍", at: .now),
        PiChatMessage(sessionID: "s1", entryID: "2", seq: 2, role: .pi, text: older, at: .now),
        PiChatMessage(sessionID: "s1", entryID: "3", seq: 3, role: .user, text: "贴输出", at: .now),
        PiChatMessage(sessionID: "s1", entryID: "4", seq: 4, role: .pi, text: output, at: .now),
      ],
      recap: PiRecap()))
    try await Server.run(library: sandbox.directory) { server in
      let text = try await server.call("task", ["action": "peek", "task": task.id.uuidString])
      // 前 4000 字里的"过"（含开头"全部通过"的那个）都在：长串重复字符的子串查找不可靠，按个数比
      #expect(text.filter { $0 == "过" }.count == output.prefix(4000).filter { $0 == "过" }.count)
      #expect(!text.contains("尾巴") && text.contains("后面还有 \(output.count - 4000) 字"))
      #expect(!text.contains(older) && text.contains(String(older.prefix(200))))
    }
  }

  /// 不带 task 的 peek 是看板：所有没做完的事，按项目分组，做完的不列；太多时只列 60 行，说还有几件。
  @Test(.timeLimit(.minutes(1))) func cueSeesEveryOpenTaskGroupedByProject() async throws {
    let sandbox = try Sandbox()
    let store = sandbox.store
    let project = try await sandbox.project("演示")
    let mine = try await store.createTask("用户自己的事", in: project.id)
    let home = try await store.createTask("默认项目里的事")
    let done = try await store.createTask("做完的事", in: project.id)
    try await store.setStatus(done.id, .done)
    try await Server.run(library: sandbox.directory) { server in
      let text = try await server.call("task", ["action": "peek"])
      #expect(text.split(separator: "\n").filter { $0.hasPrefix("- ") }.map { String($0.prefix(while: { $0 != "（" })) } == ["- 用户自己的事", "- 默认项目里的事"])
      #expect(text.contains(mine.id.shortID) && text.contains(home.id.shortID) && !text.contains(done.heading))
      #expect(text.split(separator: "\n").filter { $0.hasSuffix("：") && !$0.hasPrefix("-") }.dropFirst().map(String.init) == ["演示：", "默认："])

      for index in 0..<70 { _ = try await store.createTask("事 \(index)") }
      let lines = try await server.call("task", ["action": "peek"]).split(separator: "\n")
      #expect(lines.count == 60)
      let shown = lines.filter { $0.hasPrefix("- ") }.count
      #expect(lines.last.map(String.init) == "还有 \(72 - shown) 件")
    }
  }

  /// 看板上一件事的近况取在做的那一步；步骤都做完、整件事还没收尾时取最后做完的那一步（它的会话是最新的进展），不落回第一步。
  @Test(.timeLimit(.minutes(1))) func theBoardShowsTheStepLastWorkedOn() async throws {
    let sandbox = try Sandbox()
    let store = sandbox.store
    let task = try await store.createTask("加语言参数")
    let first = try await store.createTask("加 --lang", under: task.id), second = try await store.createTask("写 README", under: task.id)
    try await store.linkCard(first.id, toSession: "s1")
    try await store.linkCard(second.id, toSession: "s2")
    let recorder = PiStateRecorder(store: store, hostID: "mac-a")
    for session in ["s1", "s2"] { try await recorder.update(sessionID: session, state: .settled) }
    try await Server.run(library: sandbox.directory) { server in
      func shown(_ step: Card) async throws -> Bool { try await server.call("task", ["action": "peek"]).contains("· \(step.heading) ›") }

      _ = try await store.toggleDone(first.id)
      #expect(try await shown(second))  // 在做第二步
      _ = try await store.toggleDone(second.id)
      // 完成时刻直接给定先后（毫秒）：取的是最后做完的那一步，不是排在最后的那一步
      func finish(_ step: Card, atMinute minute: Int) throws {
        try RawDB(sandbox.directory.appending(path: "cuepad.db"))
          .exec("UPDATE cards SET completedAt = \(1_800_000_000_000 + minute * 60_000) WHERE id = '\(step.id.uuidString.lowercased())'")
      }
      try finish(first, atMinute: 0)
      try finish(second, atMinute: 1)
      #expect(try await shown(second))
      try finish(first, atMinute: 2)
      #expect(try await shown(first))
    }
  }
}
#endif
