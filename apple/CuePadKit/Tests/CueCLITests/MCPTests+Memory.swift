#if os(macOS)
import CueStore
import Foundation
import Testing

/// Cue 经 `cuepad mcp` 改一条记着的规矩、看全部定时。
extension MCPTests {
  /// 他改了说法：新的一条取代旧的（同一次写入里忘掉旧的），钉不钉照旧的；定时不能被替换，整件退回、什么都不写。
  @Test func aChangedRuleReplacesTheOldOneInsteadOfPilingUp() async throws {
    let sandbox = try Fixture()
    let store = sandbox.store
    try await Server.run(library: sandbox.directory) { server in
      try await server.call("memory", ["action": "note", "text": "推送前先跑测试", "pin": true, "his": true])
      try await server.call("memory", ["action": "note", "text": "周会在周一"])
      let reply = try await server.call("memory", ["action": "note", "text": "推送前先跑测试和 lint", "his": true, "replaces": [0]])
      #expect(reply.contains("#2") && reply.contains("一直记着") && reply.contains("#0"))

      let kept = try await store.recentCueMemory().lines
      #expect(kept.map(\.text).sorted() == ["周会在周一", "推送前先跑测试和 lint"])
      #expect(kept.first { $0.text == "推送前先跑测试和 lint" }?.pinned == true)
      #expect(kept.first { $0.text == "推送前先跑测试和 lint" }?.source == .known(.you))

      try await server.call("memory", ["action": "remind", "text": "看周报", "at": Self.tomorrow(hour: 9)])
      #expect(try await server.refused("memory", ["action": "note", "text": "看月报", "replaces": [3, 1]]).contains("定时"))
      #expect(try await store.cueMemory().lines.count == 4)
      #expect(try await store.cueScheduleLines().map(\.text) == ["看周报"])
      #expect(try await store.recentCueMemory().count == 2)
    }
  }

  /// schedules 列出全部定时：序号、下一次、怎么重复、挂在哪件任务上。
  @Test func cueListsAllItsSchedules() async throws {
    let sandbox = try Fixture()
    let store = sandbox.store
    let task = try await store.createTask("整理周报")
    try await Server.run(library: sandbox.directory) { server in
      #expect(try await server.call("memory", ["action": "schedules"]) == "没有定时。")
      try await server.call("memory", ["action": "note", "text": "回复要短"])
      try await server.call("memory", ["action": "remind", "text": "提醒他交周报", "at": Self.tomorrow(hour: 9), "repeat": "FREQ=DAILY", "task": task.id.uuidString])
      try await server.call("memory", ["action": "remind", "text": "续费域名", "at": Self.tomorrow(hour: 18)])

      let lines = try await server.call("memory", ["action": "schedules"]).split(separator: "\n").map(String.init)
      #expect(lines.count == 2)
      #expect(lines[0].hasPrefix("#1 提醒他交周报") && lines[0].contains("9:00") && lines[0].contains("每天 9:00"))
      #expect(lines[0].contains("挂在「整理周报」（\(task.id.shortID)）"))
      #expect(lines[1].hasPrefix("#2 续费域名") && lines[1].contains("18:00") && lines[1].contains("一次"))
    }
  }

  /// 后台整理记忆的大脑经 `cuepad mcp --dream` 收口一直记着的：同一件事的几条并成一条（有他的原话就算他的）、一次性的放回普通记忆，只动一直记着的。
  @Test func theDreamTidiesWhatIsAlwaysKept() async throws {
    let sandbox = try Fixture()
    let store = sandbox.store
    let rules: [(String, CueLineSource)] = [("回复要短", .you), ("回复先说结论", .cue), ("以后推送都不用问", .you), ("这周在修登录页", .cue)]
    for (text, source) in rules {
      try await store.noteCueLine(text, source: source, pinned: true)
      try await Task.sleep(for: .milliseconds(2))  // 序号按记下的先后
    }
    try await store.noteCueLine("周会在周一", source: .cue)
    try await Server.run(library: sandbox.directory, arguments: ["mcp", "--dream"]) { server in
      let tools = try #require(try await server.request("tools/list", [:])["tools"] as? [[String: Any]])
      #expect(tools.compactMap { $0["name"] as? String } == ["merge", "tidy"])

      #expect(try await server.call("tidy", ["lines": [0, 1], "text": "回复要短，先说结论"]).contains("#5"))
      try await server.call("tidy", ["lines": [3]])
      #expect(try await server.refused("tidy", ["lines": [4], "text": "周会"]).contains("不是一直记着"))
      #expect(try await server.refused("tidy", ["lines": [2], "text": "以后都不用问"]).contains("至少两条"))
    }
    let kept = try await store.recentCueMemory().lines
    #expect(kept.filter(\.pinned).map(\.text).sorted() == ["以后推送都不用问", "回复要短，先说结论"])
    #expect(kept.first { $0.text == "回复要短，先说结论" }?.source == .known(.you))
    #expect(kept.contains { $0.text == "这周在修登录页" && !$0.pinned })
    #expect(!kept.contains { $0.text == "回复要短" || $0.text == "回复先说结论" })
  }

  /// 明天这个钟点（本机时区），照 remind 认的 yyyy-MM-dd HH:mm 写。
  static func tomorrow(hour: Int) -> String {
    let day = Calendar.current.date(byAdding: .day, value: 1, to: .now)!
    let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
  }
}
#endif
