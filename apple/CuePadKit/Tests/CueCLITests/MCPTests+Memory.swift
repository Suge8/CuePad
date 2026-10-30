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
      #expect(try await server.refused("memory", ["action": "note", "text": "看月报", "replaces": ["#3", 1]]).contains("定时"))
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
