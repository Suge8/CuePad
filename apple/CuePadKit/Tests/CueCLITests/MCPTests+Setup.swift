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

  /// Cue 写错模型名（如把 claude 拼成 claaude）：开工当场退回、列出能选的，不写投送请求；照抄清单里的就开得出来。
  @Test func cueTypoModelIsRefusedBeforeAnythingIsSent() async throws {
    let sandbox = try Fixture()
    let store = sandbox.store
    try await Self.enable(store)
    try await Server.run(library: sandbox.directory) { server in
      let added = try await server.call("task", ["action": "add", "title": "修好登录白屏"])
      let id = try #require(added.firstMatch(of: /（([0-9a-f]{8})）/).map { String($0.1) })
      let refusal = try await server.refused("task", ["action": "start", "task": id, "agent": "pi", "model": "anthropic/claaude-opus-5-5"])
      #expect(refusal.contains("Pi 没有 anthropic/claaude-opus-5-5：能选的是 anthropic/claude-opus-5-5、openai-codex/gpt-6"), "\(refusal)")
      #expect(try await store.deliveryRequests().isEmpty)
      _ = try await server.call("task", ["action": "start", "task": id, "agent": "pi", "model": "anthropic/claude-opus-5-5"])
      #expect(try await store.deliveryRequests().count == 1)
    }
  }

  @Test func cueLooksAtItsBrainAgentsQuotaAndProjects() async throws {
    let sandbox = try Fixture()
    let store = sandbox.store
    try await Self.enable(store)
    try await store.recordQuota(
      QuotaReport(
        provider: "anthropic", windows: [
          QuotaWindow(seconds: 18_000, used: 0.4, resetsAt: .now.addingTimeInterval(-60)),
          QuotaWindow(seconds: QuotaWindow.week, used: 0.86, resetsAt: .now.addingTimeInterval(2 * 86_400)),
        ],
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
        "他在终端里开的 Claude Code 会话：不能发图、停下这一轮、换模型、用斜杠命令", "anthropic「Max」（吃紧） 5 小时 已过重置时间，等新的观测；本周 已用 86%", "卡着", "记忆 2 条（一直记着 1 条）",
        "官网（\(folder)）",
      ] {
        #expect(overview.contains(expected), "\(expected) 不在：\n\(overview)")
      }
      let agents = try await server.call("setup", ["action": "look", "part": "agents"])
      // 模型那一行带着卡着的窗口几点重置：额度用完时看这一块就够定时接着做
      let opus = try #require(agents.split(separator: "\n").first { $0.contains("anthropic/claude-opus-5-5（") }, "\(agents)")
      #expect(opus.contains("（Claude Opus 5.5，默认） · 强度 low/medium/high · fast · 额度：anthropic「Max」 本周 已用 86%，") && opus.hasSuffix(" 重置"), "\(opus)")
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
      #expect(try await server.refused("setup", ["action": "set", "model": "anthropic/claude-nope"]).contains("Pi 没有 anthropic/claude-nope：能选的是 anthropic/claude-opus-5-5、openai-codex/gpt-6"))
      #expect(try await server.refused("setup", ["action": "set", "model": "openai-codex/gpt-6", "fast": true]).contains("不支持 fast"))
      #expect(try await store.cueProfile()?.model == nil)

      let switched = try await server.call("setup", ["action": "set", "model": "openai-codex/gpt-6", "effort": "high"])
      #expect(switched.contains("下一轮换上") && !switched.contains("换新大脑"), "\(switched)")
      let changed = try #require(try await store.cueProfile())
      #expect(changed.model == "openai-codex/gpt-6" && changed.effort == .known(.high))

      // 模型回到默认要重开大脑（同管理器）
      #expect(try await server.call("setup", ["action": "set", "model": "default"]).contains("换新大脑"))
      #expect(try await store.cueProfile()?.model == nil)

      #expect(try await server.call("setup", ["action": "set", "agent": "claude", "name": "小 Q"]).contains("换新大脑"))
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

      try await server.call("setup", ["action": "project", "project": "官网", "folder": "/"])
      #expect(try await store.directory(of: project.id) == "/")
      // 没用到的参数填成空值（有的模型这样填）是没写：介绍与文件夹不动；清掉、解除要写 none
      try await server.call("setup", ["action": "project", "project": "官网", "title": "落地页", "intro": "", "folder": ""])
      #expect(try await store.project(project.id)?.name == "落地页")
      #expect(try await store.project(project.id)?.intro == "公司落地页")
      #expect(try await store.directory(of: project.id) == "/")
      try await server.call("setup", ["action": "project", "project": "落地页", "intro": "none", "folder": "none"])
      #expect(try await store.project(project.id)?.intro == nil)
      #expect(try await store.directory(of: project.id) == nil)
    }
  }
}
#endif
