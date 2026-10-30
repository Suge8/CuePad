import CueStore
import CueText
import Foundation

extension CueTools {
  /// setup 的说明与参数：Cue 读自己与它运行的那台 Mac（大脑、Agent 与模型、额度、技能与规则、项目、健康，`look` 在 `CueTools+SetupLook`），改自己的大脑设置与项目。
  static var setupDefinition: [String: Any] {
    [
      "name": "setup",
      "description": """
        你自己与你运行的这台 Mac 的设置。look{part?} 只读：不带 part 是总览（大脑与它好不好、各家 Agent 能不能用与边界、订阅额度、记忆与定时、技能与规则、项目）；
        part=brain|agents|quota|skills|projects 看那一块的全部（agents 带每家能选的模型、各自花哪个账号的额度）；
        set{agent?,model?,effort?,fast?,name?} 改你自己的大脑：agent 要在这台 Mac 上能用，换 agent 不写 model 就用那家的默认；model 照这家的写法（look agents 里有），写 default 回到这家的默认；fast 只有支持的模型能开。改的都在这一轮做完后生效，换 agent、name、fast 时换个新大脑（记忆照旧）。额度吃紧时可换到宽裕的那家或模型，要等额度恢复再换回就 memory remind 定个时；
        project{project,new?,title?,intro?,folder?}：project 写项目名，new:true 才新建（防拼错建出新的）；title 改名，intro 是一句话介绍（空串清掉），folder 绑定这台 Mac 上的文件夹（绝对路径或 ~/，要存在；空串解除）；
        tidy{} 请这台 Mac 一键整理技能与规则（look skills 里"一键整理"那几件）；同名去重、内容不同的规则合并要他挑，告诉他在技能与规则页里做。
        """,
      "inputSchema": schema(
        [
          "action": ["type": "string", "enum": ["look", "set", "project", "tidy"]],
          "part": ["type": "string", "enum": LookPart.allCases.map(\.rawValue)],
          "agent": ["type": "string", "enum": AgentKind.allCases.map(\.rawValue)], "model": string,
          "effort": ["type": "string", "enum": PiThinkingLevel.allCases.map(\.rawValue)], "fast": ["type": "boolean"], "name": string,
          "project": string, "new": ["type": "boolean"], "title": string, "intro": string, "folder": string,
        ], required: ["action"]),
      "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
    ]
  }

  enum LookPart: String, CaseIterable {
    case brain, agents, quota, skills, projects
  }

  func setup(_ args: Args) async throws -> Result {
    switch try args.required("action") {
    case "look":
      let part = try args.string("part").map { raw in
        guard let part = LookPart(rawValue: raw) else { throw Failure("part 写 \(LookPart.allCases.map(\.rawValue).joined(separator: " / "))：\(raw)") }
        return part
      }
      return .ok(try await look(part))
    case "set": return .ok(try await setBrain(args))
    case "project": return .ok(try await setProject(args))
    case "tidy": return try await tidy()
    case let other: throw Failure("setup 没有 \(other)：可用 look / set / project / tidy")
    }
  }

  // MARK: set

  /// 写 `model` 时回到这家默认的写法。
  static let defaultModel = "default"

  private func setBrain(_ args: Args) async throws -> String {
    let keys = ["agent", "model", "effort", "fast", "name"].filter { args.raw[$0] != nil }
    guard !keys.isEmpty else { throw Failure("set 至少给 agent、model、effort、fast、name 中的一项") }
    let current = try await store.cueProfile() ?? CueProfile()
    let host = try await host()
    let mac = try await store.macAgents(on: host)

    let kind = try args.string("agent").map { raw in
      guard let kind = AgentKind(rawValue: raw) else { throw Failure("agent 写 \(Self.agents)：\(raw)") }
      return kind
    } ?? current.runtime.known
    guard let kind, let agent = mac.agent(kind) else {
      let why = kind.flatMap { mac.problem($0) }.map { "：\($0)" } ?? ""
      let usable = mac.kinds.map(\.rawValue).joined(separator: "、")
      throw Failure("\(kind?.name ?? current.runtime.rawValue) 在「\(mac.shownName)」上用不了\(why)。能用的：\(usable.isEmpty ? "无" : usable)")
    }
    let switching = kind != current.runtime.known

    var model = switching ? nil : current.model
    if let raw = args.string("model")?.trimmingCharacters(in: .whitespaces) {
      model = raw.isEmpty || raw == Self.defaultModel ? nil : try modelRef(raw, of: agent)
    }
    let option = model.flatMap(agent.kind.modelKey).flatMap { key in agent.models.first { $0.key == key } } ?? (model == nil ? agent.defaultModel : nil)

    var notes: [String] = []
    var fast = switching ? false : current.fast
    if let wanted = args.bool("fast") {
      guard !wanted || option?.supportsFast == true else {
        throw Failure("\(model ?? "\(agent.kind.name) 的默认模型") 不支持 fast：look agents 里标着 fast 的才能开")
      }
      fast = wanted
    } else if fast, option?.supportsFast != true {
      fast = false
      notes.append("这个模型不支持 fast，已关掉")
    }

    var effort = current.effort
    if let raw = args.string("effort") {
      guard let level = PiThinkingLevel(rawValue: raw) else { throw Failure("effort 写 \(PiThinkingLevel.allCases.map(\.rawValue).joined(separator: " / "))") }
      effort = .known(level)
      if let levels = option?.thinkingLevels, level.clamped(to: levels) != level {
        notes.append("这个模型没有 \(raw)，实际按 \(level.clamped(to: levels).rawValue)")
      }
    }

    var name = current.name
    if let raw = args.string("name") {
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, !trimmed.contains(where: \.isNewline) else { throw Failure("name 写一个不空的名字（一行）") }
      guard CueName.width(trimmed) <= CueName.limit else { throw Failure("name 宽过上限 \(CueName.limit)（汉字算 2）：写短些") }
      name = trimmed
    }

    let wanted = (kind, model, effort, fast, name)
    let profile = try await store.updateCueProfile { profile in
      (profile.runtime, profile.model, profile.effort, profile.fast, profile.name) = (.known(wanted.0), wanted.1, wanted.2, wanted.3, wanted.4)
    }
    guard profile != current else { return "本来就是这样，没改。" }
    // 要不要换新大脑由管理器定（`CueKeeper` 的 `needsNewBrain`），这里不另判一份：说明里写着哪几样会换
    return (["改好了：\(Self.brainLine(profile, agent: agent))"] + notes + ["这一轮做完后生效"]).joined(separator: "；") + "。"
  }

  /// 照这家的写法核对 model：写不出键的退回；有清单的要在清单里。返回这家的标准写法（`AgentKind.modelRef`）。
  private func modelRef(_ raw: String, of agent: MacAgent) throws -> String {
    guard let key = agent.kind.modelKey(raw) else {
      throw Failure("\(agent.kind.name) 的 model 写 provider/id（如 anthropic/claude-opus-5-5）：\(raw)")
    }
    guard agent.models.isEmpty || agent.models.contains(where: { $0.key == key }) else {
      throw Failure("\(agent.kind.name) 在这台 Mac 上没有 \(raw)：用 setup look agents 看能选的")
    }
    return agent.kind.modelRef(key)
  }

  /// "Pi · anthropic/claude-opus-5-5 · 强度 low · fast 关 · 名字 Cue"：model 为 nil 写这家的默认是哪个。
  static func brainLine(_ profile: CueProfile, agent: MacAgent?) -> String {
    let fallback = agent.flatMap { agent in agent.model.map { "默认（\(agent.kind.modelRef($0))）" } } ?? "默认"
    let model = profile.model ?? fallback
    let effort = profile.effort?.rawValue ?? "默认"
    return "\(profile.runtime.known?.name ?? profile.runtime.rawValue) · \(model) · 强度 \(effort) · fast \(profile.fast ? "开" : "关") · 名字 \(profile.name)"
  }

  // MARK: project

  /// Cue 新建的项目用的颜色：同新建项目表单的第一种（App 的 `Palette.projectColors`）。
  static let newProjectColor = "#D9774B"

  private func setProject(_ args: Args) async throws -> String {
    let ref = try args.required("project").trimmingCharacters(in: .whitespacesAndNewlines)
    let title = args.string("title")?.trimmingCharacters(in: .whitespacesAndNewlines)
    let intro = args.string("intro").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    if let title, title.isEmpty { throw Failure("title 不能是空的") }
    let folder = try args.string("folder").map(folderPath)
    var done: [String] = []
    let project: Project
    if args.bool("new") == true {
      if let existing = try await store.projects().first(where: { $0.name.caseInsensitiveCompare(ref) == .orderedSame }) {
        throw Failure("已有项目「\(existing.name)」：去掉 new 就是改它")
      }
      project = try await store.createProject(name: ref, color: Self.newProjectColor)
      done.append("建好了项目「\(ref)」")
    } else {
      guard title != nil || intro != nil || folder != nil else { throw Failure("project 要给 title、intro 或 folder；新建带 new:true") }
      project = try await self.project(ref)
    }
    if title != nil || intro != nil {
      try await store.updateProject(project.id) { edited in
        if let title { edited.name = title }
        if let intro { edited.intro = intro.isEmpty ? nil : intro }
      }
      if let title { done.append("改名为「\(title)」") }
      if let intro { done.append(intro.isEmpty ? "清掉了介绍" : "写好了介绍") }
    }
    if let folder {
      try await store.setDirectory(folder, for: project.id)
      done.append(folder.map { "绑定了 \($0)" } ?? "解除了文件夹")
    }
    return done.joined(separator: "，") + "。"
  }

  /// folder 写的路径：空串是解除（nil）；`~` 展开、要是这台 Mac 上已有的文件夹，存标准写法。
  private func folderPath(_ raw: String) throws -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let expanded = NSString(string: trimmed).expandingTildeInPath
    guard expanded.hasPrefix("/") else { throw Failure("folder 写绝对路径或 ~/ 开头：\(raw)") }
    let url = URL(filePath: expanded, directoryHint: .isDirectory).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw Failure("这台 Mac 上没有文件夹 \(url.path)：先开任务让会话建好，或问他在哪")
    }
    let path = url.path(percentEncoded: false)
    return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
  }

  // MARK: tidy

  /// 请这台 Mac 做一键整理（`AgentLibrary.automaticOrders`），等结果同说话（`spoken`）。
  private func tidy() async throws -> Result {
    let host = try await host()
    guard let library = try await store.agentLibrary(host: host) else { throw Failure("这台 Mac 还没报过技能与规则：稍后再看 setup look skills") }
    let manual = library.tidies.count - library.automaticTidies.count
    let rest = manual > 0 ? "另有 \(manual) 件要他挑（同名去重、规则合并），在技能与规则页里做。" : ""
    guard !library.automaticOrders.isEmpty else { return .ok("没有能一键整理的。" + rest) }
    let request = try await store.requestTidy(library.automaticOrders, on: host)
    let spoken = try await spoken(request, "一键整理 \(library.automaticTidies.count) 件技能与规则", tail: request.id.shortID, from: host)
    return Result(text: spoken.text + rest, isError: spoken.isError)
  }
}
