#if os(macOS)
import CueAgent
import CueStore
import Foundation
import Testing

extension MCPTests {
  /// Cue 在 mac-a 上用 Pi 当大脑：Pi 的 Opus 花 Max 账号的额度（本周用了 86%，卡着），终端里的 Claude Code 也能用，Codex 没登录。
  private static let opus = PiModelOption(
    key: PiModelKey(provider: "anthropic", id: "claude-opus-5-5"), name: "Claude Opus 5.5", thinkingLevels: [.low, .medium, .high],
    account: PiAccount(kind: .oauth, scope: "max-1"), supportsFast: true)
  private static let gpt = PiModelOption(key: PiModelKey(provider: "openai-codex", id: "gpt-6"), name: "GPT-6", thinkingLevels: [.low, .high])

  private static func enable(_ store: CueStore) async throws {
    try await store.updateCueProfile {
      $0.hostID = "mac-a"
      $0.enabledAt = .now
    }
    try await store.recordMacAgents(
      host: "mac-a", name: "工作室",
      [
        MacAgent(kind: .pi, model: opus.key, models: [opus, gpt]),
        MacAgent(kind: .claudeCode, model: PiModelKey(provider: "claude", id: "opus"), models: []),
      ],
      problems: [MacAgentProblem(kind: .codex, reason: .notLoggedIn)])
  }

  @Test func cueLooksAtItsBrainAgentsQuotaAndProjects() async throws {
    let sandbox = try Fixture()
    let store = sandbox.store
    try await Self.enable(store)
    try await store.recordQuota(
      QuotaReport(
        provider: "anthropic", windows: [QuotaWindow(seconds: QuotaWindow.week, used: 0.86, resetsAt: .now.addingTimeInterval(2 * 86_400), isBinding: true)],
        complete: true, account: PiAccount(kind: .oauth, scope: "max-1", name: "Max")),
      host: "mac-a")
    try CueHealth(phase: .running, shiftStartedAt: .now, runtime: .pi, lastFailure: .init(at: .now, text: "429 rate limited")).write(library: sandbox.directory)
    try await store.noteCueLine("改数据库结构前先问我", source: .you, pinned: true)
    try await store.noteCueLine("发布脚本在 scripts/release.sh", source: .cue)
    let folder = sandbox.directory.appending(path: "site").path
    try await store.setDirectory(folder, for: try await sandbox.project("官网").id)

    try await Server.run(library: sandbox.directory) { server in
      let overview = try await server.call("setup", ["action": "look"])
      for expected in [
        "大脑：Pi · 默认（anthropic/claude-opus-5-5）", "在「工作室」", "健康：值班中", "429 rate limited", "codex 用不了：没登录",
        "他在终端里开的 Claude Code 会话：不能发图、停下这一轮、换模型、用斜杠命令", "anthropic「Max」（吃紧） 本周 已用 86%", "卡着", "记忆 2 条（一直记着 1 条）",
        "官网（\(folder)）",
      ] {
        #expect(overview.contains(expected), "\(expected) 不在：\n\(overview)")
      }
      let agents = try await server.call("setup", ["action": "look", "part": "agents"])
      #expect(agents.contains("anthropic/claude-opus-5-5（Claude Opus 5.5，默认） · 强度 low/medium/high · fast · 额度：anthropic「Max」 本周 已用 86%"), "\(agents)")
      #expect(agents.contains("openai-codex/gpt-6（GPT-6） · 强度 low/high"), "\(agents)")
      #expect(try await server.call("setup", ["action": "look", "part": "quota"]).contains("花它的模型：pi anthropic/claude-opus-5-5"))
      #expect(try await server.refused("setup", ["action": "look", "part": "money"]).contains("brain / agents / quota / skills / projects"))
    }
  }

  @Test func cueChangesItsOwnBrainWithinWhatTheMacCanRun() async throws {
    let sandbox = try Fixture()
    let store = sandbox.store
    try await Self.enable(store)
    try await Server.run(library: sandbox.directory) { server in
      #expect(try await server.refused("setup", ["action": "set"]).contains("至少给"))
      #expect(try await server.refused("setup", ["action": "set", "agent": "codex"]).contains("没登录"))
      #expect(try await server.refused("setup", ["action": "set", "model": "anthropic/claude-nope"]).contains("look agents"))
      #expect(try await server.refused("setup", ["action": "set", "model": "openai-codex/gpt-6", "fast": true]).contains("不支持 fast"))
      #expect(try await store.cueProfile()?.model == nil)

      let switched = try await server.call("setup", ["action": "set", "model": "openai-codex/gpt-6", "effort": "high"])
      #expect(switched.contains("这一轮做完后换上") && !switched.contains("换新大脑"), "\(switched)")
      let changed = try #require(try await store.cueProfile())
      #expect(changed.model == "openai-codex/gpt-6" && changed.effort == .known(.high))

      let moved = try await server.call("setup", ["action": "set", "agent": "claude", "name": "小 Q"])
      #expect(moved.contains("换新大脑"), "\(moved)")
      let profile = try #require(try await store.cueProfile())
      #expect(profile.runtime == .known(.claudeCode) && profile.model == nil && profile.name == "小 Q")
      #expect(try await server.call("setup", ["action": "set", "agent": "claude"]).contains("没改"))
    }
  }

  @Test func cueCreatesRenamesAndBindsProjects() async throws {
    let sandbox = try Fixture()
    let store = sandbox.store
    try await Self.enable(store)
    let folder = sandbox.directory.appending(path: "site", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try await Server.run(library: sandbox.directory) { server in
      // 拼错的名字不静默新建
      #expect(try await server.refused("setup", ["action": "project", "project": "官网", "intro": "公司落地页"]).contains("没有项目「官网」"))
      #expect(try await store.projects().map(\.name) == ["默认"])

      try await server.call("setup", ["action": "project", "project": "官网", "new": true, "intro": "公司落地页", "folder": folder.path])
      let project = try #require(try await store.projects().first { $0.name == "官网" })
      #expect(project.intro == "公司落地页")
      #expect(try await store.directory(of: project.id) == folder.path)
      #expect(try await server.refused("setup", ["action": "project", "project": "官网", "new": true]).contains("已有项目"))
      #expect(try await server.refused("setup", ["action": "project", "project": "官网", "folder": "/no/such/folder"]).contains("没有文件夹"))

      try await server.call("setup", ["action": "project", "project": "官网", "title": "落地页", "folder": ""])
      #expect(try await store.project(project.id)?.name == "落地页")
      #expect(try await store.directory(of: project.id) == nil)
    }
  }
}
#endif
