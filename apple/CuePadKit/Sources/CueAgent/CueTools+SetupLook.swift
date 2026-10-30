import CueStore
import Foundation

/// `setup look`：Cue 读自己与它运行的那台 Mac。总览每块几行；`part` 给那一块的全部。只读库与本机的健康文件（`CueHealth`），不碰别的。
extension CueTools {
  func look(_ part: LookPart?) async throws -> String {
    let now = Date()
    let host = try await host()
    let profile = try await store.cueProfile() ?? CueProfile()
    let mac = try await store.macAgents(on: host)
    let quotas = try await store.accountQuotas().filter { $0.hostID == host }
    let lines: [String]
    switch part {
    case nil:
      let library = try await store.agentLibrary(host: host), facts = try await projectFacts(), memory = try await memory()
      lines = brain(profile, mac: mac, now: now, detail: false) + agents(mac, profile: profile, quotas: quotas, now: now, detail: false)
        + quota(quotas, mac: mac, now: now, detail: false) + [memory] + skills(library, projects: [], detail: false) + projects(facts, detail: false)
    case .brain: lines = brain(profile, mac: mac, now: now, detail: true)
    case .agents: lines = agents(mac, profile: profile, quotas: quotas, now: now, detail: true)
    case .quota: lines = quota(quotas, mac: mac, now: now, detail: true)
    case .skills: lines = skills(try await store.agentLibrary(host: host), projects: try await store.projects(), detail: true)
    case .projects: lines = projects(try await projectFacts(), detail: true)
    }
    return lines.joined(separator: "\n")
  }

  // MARK: 大脑

  private func brain(_ profile: CueProfile, mac: MacAgents, now: Date, detail: Bool) -> [String] {
    let agent = profile.runtime.known.flatMap(mac.agent)
    var lines = ["大脑：\(Self.brainLine(profile, agent: agent)) · 在「\(mac.shownName)」"]
    guard let health = CueHealth.read(library: store.libraryDirectory) else { return lines + ["健康：还没有记录（这台的管理器还没写过）"] }
    let clip = detail ? 2000 : 120
    lines.append("健康：" + Self.phase(health, now: now))
    if let failure = health.lastFailure { lines.append("最近出错 \(CueScheduleWords.time(failure.at, now: now))：\(CueEnvelope.clip(failure.text, clip))") }
    if let failover = health.failover {
      lines.append("最近自动换大脑 \(CueScheduleWords.time(failover.at, now: now))：从 \(failover.from.name) 换到 \(failover.to.name)，\(failover.reason)")
    }
    if detail, let agent { lines += Self.limits(agent.kind).map { "  \($0)" } }
    return lines
  }

  private static func phase(_ health: CueHealth, now: Date) -> String {
    switch health.phase {
    case .starting: return "正在起大脑"
    case .running: return "值班中" + (health.shiftStartedAt.map { "（这个班次 \(CueScheduleWords.time($0, now: now)) 起）" } ?? "")
    case .restarting:
      let retry = health.nextRetry.map { "，\(CueScheduleWords.time($0, now: now)) 自动重起" } ?? ""
      return "出了问题\(retry)（连续失败 \(health.failures) 次）"
    }
  }

  // MARK: Agent

  private func agents(_ mac: MacAgents, profile: CueProfile, quotas: [AccountQuota], now: Date, detail: Bool) -> [String] {
    guard mac.modifiedAt != .distantPast else { return ["Agent：\(mac.whyNone)"] }
    var lines = ["Agent（「\(mac.shownName)」，开工不写 agent 用 \(mac.kinds.first?.rawValue ?? "无")）："]
    for kind in AgentKind.allCases {
      guard let agent = mac.agent(kind) else {
        if let problem = mac.problem(kind) { lines.append("- \(kind.rawValue) 用不了：\(problem)") }
        continue
      }
      let brain = profile.runtime.known == kind ? " · 你的大脑" : ""
      let model = agent.model.map { " · 默认 \(kind.modelRef($0))" } ?? ""
      let count = agent.models.isEmpty ? " · 没有模型清单（用它自己的默认）" : " · \(agent.models.count) 个模型"
      lines.append("- \(kind.rawValue) 能用\(brain)\(model)\(count)")
      lines += Self.limits(kind).map { "  \($0)" }
      guard detail else { continue }
      lines += agent.models.map { option in "  - " + Self.model(option, of: agent, quotas: quotas, now: now) }
    }
    return lines
  }

  /// 一个模型："anthropic/claude-opus-5-5（Claude Opus 5.5，默认）· 强度 low/medium/high · fast · 不能看图 · 额度：anthropic 本周 已用 85%"。
  private static func model(_ option: PiModelOption, of agent: MacAgent, quotas: [AccountQuota], now: Date) -> String {
    let named = [option.name.isEmpty ? nil : option.name, option.key == agent.model ? "默认" : nil].compactMap(\.self)
    var parts = [agent.kind.modelRef(option.key) + (named.isEmpty ? "" : "（\(named.joined(separator: "，"))）")]
    if !option.thinkingLevels.isEmpty { parts.append("强度 " + option.thinkingLevels.map(\.rawValue).joined(separator: "/")) }
    if option.supportsFast { parts.append("fast") }
    if option.acceptsImages == false { parts.append("不能看图") }
    if let quota = option.quota(in: quotas) { parts.append("额度：" + CueQuotaWords.binding(quota, model: option.key, at: now)) }
    return parts.joined(separator: " · ")
  }

  /// 这家的边界：他在终端里开的会话少了哪几样（CuePad 托管的、你开的会话什么都能做）。
  static func limits(_ kind: AgentKind) -> [String] {
    let hosted = AgentCapabilities.of(kind, hosted: true, model: nil), terminal = AgentCapabilities.of(kind, hosted: false, model: nil)
    let missing = abilities.filter { hosted.contains($0.0) && !terminal.contains($0.0) }.map(\.1)
    guard !missing.isEmpty else { return [] }
    if terminal.isEmpty { return ["他在终端里开的 \(kind.name) 会话你只能看，说不了话"] }
    let busy = terminal.contains(.speak) && !terminal.contains(.abort) ? "；它在跑时说不进去，等它歇下" : ""
    return ["他在终端里开的 \(kind.name) 会话：不能\(missing.joined(separator: "、"))\(busy)"]
  }

  private static let abilities: [(AgentCapabilities, String)] = [
    (.speak, "说话"), (.images, "发图"), (.abort, "停下这一轮"), (.model, "换模型"), (.rename, "改名"), (.commands, "用斜杠命令"),
    (.answer, "回答它的提问"), (.end, "收掉"), (.retry, "重跑出错的一轮"),
  ]

  // MARK: 额度

  private func quota(_ quotas: [AccountQuota], mac: MacAgents, now: Date, detail: Bool) -> [String] {
    guard !quotas.isEmpty else { return ["额度：这台 Mac 没有订阅额度的记录（按量计费的不报，订阅的要等用过一次才观测到）"] }
    return ["额度："] + quotas.flatMap { quota in
      var lines = ["- " + CueQuotaWords.line(quota, at: now)]
      guard detail else { return lines }
      if let at = quota.observedAt { lines.append("  更新于 \(CueScheduleWords.time(at, now: now))") }
      let users = mac.agents.flatMap { agent in agent.models.filter { $0.quota(in: quotas) == quota }.map { "\(agent.kind.rawValue) \(agent.kind.modelRef($0.key))" } }
      if !users.isEmpty { lines.append("  花它的模型：" + users.joined(separator: "、")) }
      return lines
    }
  }

  // MARK: 记忆、技能、项目

  private func memory() async throws -> String {
    let kept = try await store.cueMemory().lines.filter { $0.deletedAt == nil && $0.remindAt == nil }
    let schedules = try await store.cueScheduleLines().count
    return "记忆 \(kept.count) 条（一直记着 \(kept.filter(\.pinned).count) 条）· 定时 \(schedules) 条"
  }

  private func skills(_ library: AgentLibrary?, projects: [Project], detail: Bool) -> [String] {
    guard let library else { return ["技能与规则：这台 Mac 还没报过"] }
    let global = library.skills(in: .global).count
    let automatic = library.automaticTidies.count, manual = library.tidies.count - automatic
    var tidy = library.tidies.isEmpty ? "不用整理" : "要整理 \(library.tidies.count) 件"
    if automatic > 0 { tidy += "（一键整理 \(automatic) 件：setup tidy）" }
    if manual > 0 { tidy += "（\(manual) 件要他在技能与规则页挑）" }
    var lines = ["技能 \(library.skills.count) 个（全局 \(global)、项目 \(library.skills.count - global)）· 规则 \(library.instructions.count) 份 · \(tidy)"]
    guard detail else { return lines }
    let named = Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    func scope(_ scope: LibraryScope) -> String {
      switch scope {
      case .global: "全局"
      case .project(let id): "项目「\(named[id] ?? id.shortID)」"
      }
    }
    lines += library.skills.map { skill in
      var parts = ["- \(scope(skill.scope)) \(skill.name)：\(CueEnvelope.clip(skill.description, 60))"]
      if skill.problem != nil { parts.append("格式不对") }
      if !skill.unseenBy.isEmpty { parts.append(skill.unseenBy.map(\.name).joined(separator: "、") + " 读不到") }
      return parts.joined(separator: " · ")
    }
    lines += library.instructions.map { instruction in
      let kind =
        switch instruction.kind {
        case .global: "全局规则"
        case .piSystem: "Pi 的系统提示"
        case .project(let id): "\(scope(.project(id)))的规则"
        }
      let unseen = library.unseen(instruction)
      let note = instruction.hash == nil ? "（还没有这个文件）" : unseen.isEmpty ? "" : "（\(unseen.map(\.name).joined(separator: "、")) 读不到）"
      return "- \(kind) \(library.shown(instruction.path))\(note)"
    }
    lines += library.tidies.map { "- 要整理：" + Self.tidyWords($0, named: named) }
    return lines
  }

  private static func tidyWords(_ tidy: LibraryTidy, named: [UUID: String]) -> String {
    let how = tidy.isAutomatic ? "（一键）" : "，要他挑"
    switch tidy.kind {
    case .stray(let moves): return "\(moves.count) 个技能在旧目录里，搬进 .agents/skills\(how)"
    case .unlinked(let agent, let skills): return "\(agent.name) 读不到 \(skills.count) 个技能，补链接\(how)"
    case .duplicate(let name, let copies): return "同名技能「\(name)」有 \(copies.count) 份，留哪份\(how)"
    case .empty(let paths): return "\(paths.count) 个空的技能目录，移走\(how)"
    case .globalInstructions: return (tidy.merges ? "各家的全局规则内容不同，合并成一份" : "各家的全局规则各写一份，换成链接") + how
    case .projectClaude(let project, _):
      return "项目「\(named[project] ?? project.shortID)」的 CLAUDE.md 挡着 AGENTS.md，" + (tidy.merges ? "合并进 AGENTS.md" : "换成链接") + how
    }
  }

  private struct ProjectFacts {
    let projects: [Project]
    /// 这台 Mac 上绑的文件夹
    let local: [UUID: String]
    let elsewhere: [DirectoryBinding]
    let here: String
  }

  private func projectFacts() async throws -> ProjectFacts {
    let host = try await host()
    return ProjectFacts(
      projects: try await store.projects(), local: try await store.projectDirectories(),
      elsewhere: try await store.directoryBindings().filter { $0.hostID != host }, here: host)
  }

  /// 总览列这么多个项目，多的只报个数。
  private static let projectsListed = 20

  private func projects(_ facts: ProjectFacts, detail: Bool) -> [String] {
    func folder(_ project: Project) -> String? { facts.local[project.id].map { NSString(string: $0).abbreviatingWithTildeInPath } }
    guard detail else {
      let names = facts.projects.prefix(Self.projectsListed).map { project in project.name + (folder(project).map { "（\($0)）" } ?? "") }
      let more = facts.projects.count > Self.projectsListed ? "…等 \(facts.projects.count) 个" : ""
      return ["项目 \(facts.projects.count) 个：" + names.joined(separator: "、") + more]
    }
    return facts.projects.map { project in
      var parts = ["- \(project.name)（\(project.id.shortID)）"]
      parts.append(folder(project).map { "文件夹 \($0)" } ?? "这台 Mac 上没绑文件夹（开工时建在工作区）")
      let others = facts.elsewhere.filter { $0.projectID == project.id }.map { "\($0.macName) 的 \($0.folder)" }
      if !others.isEmpty { parts.append("别的 Mac：" + others.joined(separator: "、")) }
      if project.isPinned { parts.append("置顶") }
      if let intro = project.intro { parts.append("介绍：\(intro)") }
      return parts.joined(separator: " · ")
    }
  }
}
