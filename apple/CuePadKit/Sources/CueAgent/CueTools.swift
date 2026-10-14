import CueStore
import CueText
import Foundation

/// Cue 的三个工具（task、tell、memory）：定义与实现。都经 `CueStore` 的业务操作，写出的投送请求与消息标明来自 Cue。
/// 返回一两句人话加 id，`structuredContent` 放 id 等字段；出错给出路（`isError`）。
public struct CueTools: Sendable {
  let store: CueStore

  public init(store: CueStore) { self.store = store }

  /// 一次调用的结果（MCP 的 `CallToolResult`）。
  public struct Result: @unchecked Sendable {
    public var text: String
    public var structured: [String: Any]
    public var isError: Bool

    static func ok(_ text: String, _ structured: [String: Any] = [:]) -> Result { Result(text: text, structured: structured, isError: false) }
  }

  /// 给 Cue 看的出错：说清楚、给出路。
  struct Failure: Error {
    let message: String
    init(_ message: String) { self.message = message }
  }

  // MARK: 定义

  static var definitions: [[String: Any]] {
    [
      [
        "name": "task",
        "description": """
          派活与跟进 CuePad 的任务（你不写代码，活交给会话做）。task 写 id 前缀或标题。
          add{title,project?,steps?,prompt?} 建任务，默认由你跟进；edit{task,title?,prompt?,steps?,project?} 改标题、草稿、追加步骤或挪到项目；
          start{task,agent?,model?,effort?,fresh?} 开工（先 edit 写好草稿）：叶子绑着会话就把草稿发进去，没绑就在项目文件夹用 agent（pi/claude/codex/opencode，缺省 pi）开新会话，model 写 provider/id（claude、codex 只写 id）；同一任务的下一步默认接着用上一步还开着的会话（要接着用就在上一步 done 之前开工），上下文太长或要换 Agent 时用 fresh:true；
          say{task,text,when:now|after|answer,value?,model?,effort?} 对叶子的会话说话（now 马上说，after 等它做完，answer 回答它的提问，value 是选项或 yes/no；带 model、effort 先给会话换上再说）；
          peek{task?,all?} 只读：不带 task 看看板，带 task 看叶子、近况、最近几轮问答与预览，all:true 看用户手上所有没做完的事；
          stop{task} 停下这一轮；follow{task,who:cue|you} 换人跟进；
          done{task,evidence} 收尾：你按证据验收过就完成，不请用户收下。evidence 写两三条证据要点。完成后它的会话没有下一步在用就结束；
          顶层任务（步骤要都完成）完成时把标题与 evidence 作为结果告诉用户，不用再 tell。
          """,
        "inputSchema": schema(
          [
            "action": ["type": "string", "enum": ["add", "edit", "start", "say", "peek", "stop", "done", "follow"]],
            "task": string, "title": string, "project": string, "steps": ["type": "array", "items": string], "prompt": string,
            "agent": ["type": "string", "enum": AgentKind.allCases.map(\.rawValue)], "model": ["type": "string", "description": "provider/id"],
            "effort": ["type": "string", "enum": PiThinkingLevel.allCases.map(\.rawValue)], "text": string,
            "when": ["type": "string", "enum": ["now", "after", "answer"]], "value": string,
            "who": ["type": "string", "enum": ["cue", "you"]], "all": ["type": "boolean"], "evidence": string, "fresh": ["type": "boolean"],
          ], required: ["action"]),
        "annotations": ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false],
      ],
      [
        "name": "tell",
        "description": """
          对用户说一句（Cue 页里你的一行）。用在你自己醒来的轮次；用户发起的一轮直接回复，只有要他允许时才 tell 带 ask。
          ask 是请他允许、等他选（"等你"），只有这几类：\(CuePrompt.asks)。选项由 CuePad 给（如推送：\(CueAsk.push.choices.joined(separator: " / "))），
          text 写清要做什么、为什么、不做会怎样；他说过这类事以后不用问的，ask 会被拒，直接做。urgent 推送到手机，只用在真要他马上看的事；task 关联到一个任务。
          withdraw 写"等你"里你问的那条的 id：你已拿了主意或情况变了，撤回它（从"等你"里消失）；可同时带 text 说为什么，或换个问法再问。
          """,
        "inputSchema": schema(
          [
            "text": string, "ask": ["type": "string", "enum": CueAsk.allCases.map(\.rawValue)], "urgent": ["type": "boolean"], "task": string,
            "withdraw": string,
          ],
          required: []),
        "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
      ],
      [
        "name": "memory",
        "description": """
          你的长期记忆，一行一条（≤280 字节），序号就是身份。note{text,pin?} 记一条；recall{query} 只读：全文找记忆、对话与任务；
          forget{line} 忘掉一条；pin{line,pinned} 一直记着或取消；remind{text,at} 到点叫醒你（ISO 8601 或 yyyy-MM-dd HH:mm）；
          merge{lo,hi,text} 把待合并的块写成一行摘要；renew{handoff} 上下文快满时写交接备忘，换新上下文接着做。
          """,
        "inputSchema": schema(
          [
            "action": ["type": "string", "enum": ["note", "recall", "forget", "pin", "remind", "merge", "renew"]],
            "text": string, "pin": ["type": "boolean"], "query": string, "line": ["type": ["string", "integer"]],
            "pinned": ["type": "boolean"], "at": string, "lo": ["type": "integer"], "hi": ["type": "integer"], "handoff": string,
          ], required: ["action"]),
        "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
      ],
    ]
  }

  private static var string: [String: Any] { ["type": "string"] }


  private static func schema(_ properties: [String: Any], required: [String]) -> [String: Any] {
    ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
  }

  // MARK: 调用

  /// 调用一个工具；工具名不认识返回 nil（协议层报参数错）。业务上的失败是 `isError` 的结果。
  public func call(_ name: String, _ arguments: [String: Any]) async -> Result? {
    let args = Args(raw: arguments)
    do {
      switch name {
      case "task": return try await task(args)
      case "tell": return try await tell(args)
      case "memory": return try await memory(args)
      default: return nil
      }
    } catch let failure as Failure {
      return Result(text: failure.message, structured: [:], isError: true)
    } catch {
      // Kit 里只有 Cue 会碰到的错误，文案本来就是写给 Cue 的（见 `CueStoreError`）
      return Result(text: (error as? LocalizedError)?.errorDescription ?? "\(error)", structured: [:], isError: true)
    }
  }

  // MARK: task

  private func task(_ args: Args) async throws -> Result {
    switch try args.required("action") {
    case "add": return try await add(args)
    case "edit": return try await edit(args)
    case "start": return try await start(args)
    case "say": return try await say(args)
    case "peek":
      if args.bool("all") == true { return try await overview() }
      return try await args.string("task") == nil ? board() : peek(try await task(args.required("task")))
    case "stop":
      let leaf = try await workingLeaf(try args.required("task"))
      let request = try await store.stopLeaf(leaf.id, host: try await host(), cue: true)
      return .ok("已请会话停下这一轮：「\(leaf.heading)」（\(leaf.id.shortID)）。", ["task": id(leaf.id), "request": id(request.id)])
    case "done": return try await done(args)
    case "follow":
      let who = try args.required("who")
      guard ["cue", "you"].contains(who) else { throw Failure("who 只能是 cue 或 you") }
      let top = try await store.setCueFollows(try await task(args.required("task")).id, who == "cue")
      return .ok("「\(top.heading)」（\(top.id.shortID)）" + (who == "cue" ? "由你跟进。" : "交还给用户，不再跟进。"), ["task": id(top.id), "follows": who == "cue"])
    case let other: throw Failure("task 没有 \(other)：可用 add / edit / start / say / peek / stop / done / follow")
    }
  }

  /// 收尾：Cue 验收过就完成（`finishTask`）；顶层任务同时把结果告诉用户，所以要 evidence。
  private func done(_ args: Args) async throws -> Result {
    let card = try await task(args.required("task"))
    _ = try await host()  // 停用后不能再收尾
    if card.status == .done { return .ok("「\(card.heading)」（\(card.id.shortID)）已经完成了。", ["task": id(card.id)]) }
    let evidence = card.parentID == nil ? try args.required("evidence") : args.string("evidence") ?? ""
    let (report, ends) = try await store.finishTask(card.id, evidence: evidence)
    return .ok(
      "「\(card.heading)」（\(card.id.shortID)）完成了" + (ends.isEmpty ? "" : "，已请 \(ends.count) 个会话结束")
        + (report.map { "；结果已告诉用户（\($0.id.shortID)）。" } ?? "。"),
      ["task": id(card.id), "requests": ends.map { id($0.id) }, "report": report.map { id($0.id) } ?? NSNull()])
  }

  private func add(_ args: Args) async throws -> Result {
    let heading = try args.required("title")
    let project = try await args.string("project").asyncMap(project)
    let created = try await store.createTask(heading, in: project?.id)
    var steps: [UUID] = []
    for step in args.strings("steps") ?? [] where !step.trimmingCharacters(in: .whitespaces).isEmpty {
      steps.append(try await store.createTask(step, under: created.id).id)
    }
    let top = try await store.setCueFollows(created.id, true)
    var text = "建好了「\(top.heading)」（\(top.id.shortID)）" + (steps.isEmpty ? "" : "，\(steps.count) 个步骤")
    var prompt: UUID?
    if let body = args.string("prompt") {
      let draft = try await store.createCard(body: body, under: top.id)
      prompt = draft.id
      let leaf = try await store.workingLeaf(of: top.id)
      text += leaf.id == top.id ? "，带着草稿" : "，草稿在「\(leaf.heading)」上"
    }
    text += project == nil ? "（未分类，开不了会话：用 edit 的 project 放进项目再开工）。" : "，在项目「\(project!.name)」里，由你跟进。"
    return .ok(text, ["task": id(top.id), "steps": steps.map(id), "prompt": prompt.map(id) ?? NSNull()])
  }

  private func edit(_ args: Args) async throws -> Result {
    let card = try await task(args.required("task"))
    // 绑了会话的叶子不留草稿（话在会话里说）：先查，免得标题、步骤改了一半才报错
    if args.string("prompt") != nil {
      let leaf = try await store.workingLeaf(of: card.id)
      if leaf.piSessionID != nil { throw CueStoreError.leafHasSession(leaf.heading) }
    }
    var done: [String] = []
    if let heading = args.string("title") {
      guard !heading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure("标题不能为空") }
      try await store.updateCard(card.id) { $0.body = heading }
      done.append("改了标题")
    }
    if let steps = args.strings("steps") {
      guard card.parentID == nil else { throw Failure("步骤只能加在顶层任务上：task 写它的顶层任务") }
      let existing = Set(try await store.children(of: card.id).filter(\.isTask).map { $0.heading })
      var added = 0
      for step in steps where !step.isEmpty && !existing.contains(step) {
        _ = try await store.createTask(step, under: card.id)
        added += 1
      }
      done.append("追加了 \(added) 个步骤")
    }
    if let body = args.string("prompt") {
      let leaf = try await store.workingLeaf(of: card.id)
      if let draft = try await store.draft(of: leaf.id) {
        try await store.updateCard(draft.id) { $0.body = body }
      } else {
        _ = try await store.createCard(body: body, under: leaf.id)
      }
      done.append("草稿写在「\(leaf.heading)」上")
    }
    if let ref = args.string("project") {
      let project = try await project(ref)
      let top = try await store.topTask(of: card.id)
      try await store.moveCard(top, to: .top(project: project.id), after: nil)
      done.append("连同步骤与草稿挪到了项目「\(project.name)」" + (try await store.cueProjects().first { $0.id == project.id }?.hasFolder == true ? "" : "（它没绑文件夹，开工前请用户绑一个）"))
    }
    guard !done.isEmpty else { throw Failure("edit 至少给 title、prompt、steps、project 之一") }
    return .ok("「\(card.heading)」（\(card.id.shortID)）：\(done.joined(separator: "，"))。", ["task": id(card.id)])
  }

  private func start(_ args: Args) async throws -> Result {
    let agent = try args.string("agent").map { raw -> AgentKind in
      guard let agent = AgentKind(rawValue: raw) else { throw Failure("agent 只能是 \(Self.agents)") }
      return agent
    }
    let leaf = try await workingLeaf(try args.required("task"))
    let model = try args.string("model").map { try Self.model($0, of: agent ?? .pi) }
    let effort = try Self.effort(args)
    let request = try await store.startLeaf(
      leaf.id, agent: agent, fresh: args.bool("fresh") == true, model: model, thinking: effort, host: try await host(), cue: true)
    let started = request.mode == .known(.start), continued = leaf.piSessionID == nil && !started
    let text =
      started
      ? "已请 Mac 为「\(leaf.heading)」开新会话，草稿作为第一句。"
      : continued
        ? "「\(leaf.heading)」接着用上一步的会话，草稿作为下一句发出去了（送到后这一步绑上它）。"
        : "草稿已发进「\(leaf.heading)」的会话。"
    return .ok(
      text + "（\(leaf.id.shortID)）", ["task": id(leaf.id), "request": id(request.id), "started": started, "continued": continued])
  }

  private static func effort(_ args: Args) throws -> PiThinkingLevel? {
    try args.string("effort").map { raw -> PiThinkingLevel in
      guard let level = PiThinkingLevel(rawValue: raw) else { throw Failure("effort 只能是 \(PiThinkingLevel.allCases.map(\.rawValue).joined(separator: " / "))") }
      return level
    }
  }

  /// `agent` 的取值。
  private static let agents = AgentKind.allCases.map(\.rawValue).joined(separator: " / ")

  /// 模型：provider/id；模型在这家自己命名空间里的（`AgentKind.modelProvider`：Claude Code、Codex）只写 id，提供方补成这一家，
  /// 与给大脑的 Agent 与模型清单同一种写法，照抄就行。
  private static func model(_ ref: String, of agent: AgentKind) throws -> PiModelKey {
    let parts = ref.split(separator: "/", maxSplits: 1).map(String.init)
    if parts.count == 2 { return PiModelKey(provider: parts[0], id: parts[1]) }
    guard parts.count == 1, let provider = agent.modelProvider else {
      throw Failure("\(agent.name) 的 model 写成 provider/id：提供方与模型 id 用 / 隔开（Claude Code、Codex 只写 id）")
    }
    return PiModelKey(provider: provider, id: parts[0])
  }

  private func say(_ args: Args) async throws -> Result {
    let leaf = try await workingLeaf(try args.required("task"))
    let host = try await host()
    let when = args.string("when") ?? "now"
    let config = try await config(args, of: leaf)
    let switched = config.map { "先换成 " + [$0.model.map { "\($0.provider)/\($0.id)" }, $0.thinking?.rawValue].compactMap { $0 }.joined(separator: " ") + "，再" } ?? "已"
    if when == "answer" {
      guard let value = args.string("value") ?? args.string("text") else { throw Failure("answer 要给 value（选项原文、序号或 yes/no）") }
      let request = try await store.answerLeaf(leaf.id, value, config: config, host: host, cue: true)
      return .ok("\(switched)回答「\(leaf.heading)」的提问：\(value)", ["task": id(leaf.id), "request": id(request.id)])
    }
    let timing: SayTiming
    switch when {
    case "now": timing = .now
    case "after": timing = .after
    default: throw Failure("when 只能是 now、after 或 answer")
    }
    let request = try await store.sayToLeaf(leaf.id, text: try args.required("text"), when: timing, config: config, host: host, cue: true)
    let how = request.mode == .known(.steer) ? "（会话正忙，马上说）" : request.mode == .known(.followUp) ? "（会话正忙，等它做完再说）" : ""
    return .ok("\(switched)对「\(leaf.heading)」的会话说了\(how)。（\(leaf.id.shortID)）", ["task": id(leaf.id), "request": id(request.id), "mode": request.mode.rawValue])
  }

  /// say 带的 model、effort（说话与作答之前先换上）；model 的写法同 start，只写 id 时提供方按会话是哪家补。都没带为 nil。
  private func config(_ args: Args, of leaf: Card) async throws -> PiConfig? {
    let effort = try Self.effort(args)
    guard let raw = args.string("model") else { return effort.map { PiConfig(thinking: $0) } }
    let agent = try await leaf.piSessionID.asyncMap { try await store.piSessions(sessionIDs: [$0])[$0]?.state.agent.known } ?? nil
    return PiConfig(model: try Self.model(raw, of: agent ?? .pi), thinking: effort)
  }

  private func board() async throws -> Result {
    let items = try await store.cueBoard()
    let now = Date()
    let lines = items.map { "- " + CueEnvelope.boardLine($0, now: now) }
    return .ok(
      items.isEmpty ? "你没有在跟进的事。" : "跟进中 \(items.count) 件：\n" + lines.joined(separator: "\n"),
      [
        "tasks": items.map { item -> [String: Any] in
          [
            "id": id(item.task.id), "title": item.task.heading,
            "progress": item.progress.map { ["done": $0.done, "total": $0.total] as [String: Any] } ?? NSNull(),
            "leaves": item.leaves.map { leaf -> [String: Any] in
              [
                "id": id(leaf.leaf.id), "title": leaf.leaf.heading, "session": leaf.session?.sessionID ?? NSNull(),
                "state": leaf.session?.state.rawValue ?? NSNull(),
                "launching": leaf.launching, "sending": leaf.sending, "since": iso(leaf.since),
              ]
            },
          ]
        }
      ])
  }

  /// 所有没做完的顶层任务，按项目分组（未分类在最后），至多 `overviewLimit` 行。
  private func overview() async throws -> Result {
    let items = try await store.openTopTasks()
    let names = Dictionary(uniqueKeysWithValues: try await store.projects().map { ($0.id, $0.name) })
    let now = Date()
    var lines: [(text: String, isTask: Bool)] = [], group: UUID?? = .none
    for item in items {
      if item.task.projectID != group {
        group = item.task.projectID
        lines.append(((item.task.projectID.flatMap { names[$0] } ?? "未分类") + "：", false))
      }
      lines.append(("- " + CueEnvelope.boardLine(item, now: now, showingFollower: true), true))
    }
    let room = Self.overviewLimit - 1  // 第一行是"没做完的 N 件"
    if lines.count > room {
      lines = Array(lines.prefix(room - 1))
      if lines.last?.isTask == false { lines.removeLast() }
      lines.append(("还有 \(items.count - lines.filter(\.isTask).count) 件", false))
    }
    return .ok(
      items.isEmpty ? "用户手上没有没做完的事。" : "没做完的 \(items.count) 件：\n" + lines.map(\.text).joined(separator: "\n"),
      [
        "tasks": items.map { item -> [String: Any] in
          [
            "id": id(item.task.id), "title": item.task.heading, "project": item.task.projectID.map(id) ?? NSNull(),
            "follows": item.task.cueFollows, "leaves": item.leaves.map { id($0.leaf.id) },
            "progress": item.progress.map { ["done": $0.done, "total": $0.total] as [String: Any] } ?? NSNull(),
          ]
        }
      ])
  }

  /// peek 里每个叶子最新的那条回答最多给这么多字。
  static let latestReplyLimit = 4000

  /// peek all 的文字最多这么多行（含开头一行、项目名与"还有 N 件"）。
  static let overviewLimit = 60

  /// 会话是哪家 Agent 的（本版本不认识的写 Agent）。
  private static func agentName(_ session: PiSessionState) -> String { session.agent.known?.name ?? "Agent" }

  private func peek(_ card: Card) async throws -> Result {
    let detail = try await store.cueTaskDetail(card.id)
    let now = Date()
    var lines = [
      "「\(detail.task.heading)」（\(detail.task.id.shortID)）" + (detail.progress.map { " · 步骤 \($0.done)/\($0.total)" } ?? "")
        + " · " + (detail.task.cueFollows ? "由你跟进" : "用户自己做") + " · " + status(detail.task)
    ]
    for leaf in detail.leaves {
      var head = leaf.leaf.id == detail.task.id ? "-" : "- 「\(leaf.leaf.heading)」（\(leaf.leaf.id.shortID)）\(status(leaf.leaf))"
      if let session = leaf.session {
        head += " · \(Self.agentName(session))会话「\(session.title)」\(CueEnvelope.state(session.state)) \(CueEnvelope.duration(now.timeIntervalSince(session.stateSince)))"
        if let question = session.question { head += " · 提问：\(CueEnvelope.clip(question.text, 120))" + (question.options.isEmpty ? "" : "（\(question.options.joined(separator: " / "))）") }
      } else {
        head += leaf.sending ? " · 发送中（话正送进上一步的会话）" : " · 没有会话"
      }
      lines.append(head)
      if let draft = leaf.draft { lines.append("  草稿：\(CueEnvelope.clip(CueFormat.plainText(draft.body), 200))") }
      // 最新的那条回答给全文（常是测试输出、验收证据），更早的截短
      let latest = leaf.recent.lastIndex { $0.role == .known(.pi) }
      let agent = leaf.session.map(Self.agentName) ?? "Agent"
      for (index, message) in leaf.recent.enumerated() {
        let text = CueFormat.plainText(message.text)
        guard index == latest else {
          lines.append("  \(message.role == .known(.user) ? "你" : agent)：\(CueEnvelope.clip(text, 300))")
          continue
        }
        let full = text.count > Self.latestReplyLimit
          ? String(text.prefix(Self.latestReplyLimit)) + "\n（后面还有 \(text.count - Self.latestReplyLimit) 字，截掉了）" : text
        lines.append("  \(agent)（最新的回答）：\n" + full.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n"))
      }
      if !leaf.previews.isEmpty { lines.append("  预览：" + leaf.previews.map(\.name).joined(separator: "、")) }
    }
    return .ok(
      lines.joined(separator: "\n"),
      [
        "task": id(detail.task.id), "follows": detail.task.cueFollows,
        "leaves": detail.leaves.map { leaf -> [String: Any] in
          [
            "id": id(leaf.leaf.id), "title": leaf.leaf.heading, "status": leaf.leaf.status?.rawValue ?? NSNull(),
            "session": leaf.session?.sessionID ?? NSNull(), "state": leaf.session?.state.rawValue ?? NSNull(),
            "draft": leaf.draft.map { id($0.id) } ?? NSNull(), "previews": leaf.previews.map(\.name),
          ]
        },
      ])
  }

  private func status(_ card: Card) -> String {
    switch card.status {
    case .done: "完成"
    case .inProgress: "进行中"
    case .todo: "待办"
    case nil: ""
    }
  }

  // MARK: tell

  /// 先撤回（若有 withdraw），再说（若有 text）；两样都没有是参数错。
  private func tell(_ args: Args) async throws -> Result {
    let related = try await args.string("task").asyncMap(task)
    let withdrawn = try await args.string("withdraw").asyncMap(withdraw)
    guard let text = args.string("text") else {
      guard let withdrawn else { throw Failure("要给 text（说什么）或 withdraw（撤回哪条提问）") }
      return .ok("已撤回「\(CueEnvelope.clip(CueFormat.plainText(withdrawn.text), 40))」。", ["withdrawn": id(withdrawn.id)])
    }
    let ask = try args.string("ask").map { raw -> CueAsk in
      guard let ask = CueAsk(rawValue: raw) else { throw Failure("ask 只能是这几类：\(CuePrompt.asks)；别的事你自己定，做完告诉他") }
      return ask
    }
    let message = try await store.addCueMessage(.cue, text: text, ask: ask, urgent: args.bool("urgent") ?? false, task: related?.id)
    let waits = message.choices != nil
    var structured: [String: Any] = ["message": id(message.id), "waiting": waits]
    if let withdrawn { structured["withdrawn"] = id(withdrawn.id) }
    return .ok(
      (withdrawn == nil ? "" : "已撤回原来那条，") + (waits ? "已问用户，等他选。" : "已告诉用户。") + "（\(message.id.shortID)）", structured)
  }

  /// 撤回"等你"里的一条提问（id 或前缀）。
  private func withdraw(_ ref: String) async throws -> CueMessage {
    let key = ref.trimmingCharacters(in: .whitespaces).lowercased()
    let hits = try await store.cueMessagesWaitingForYou().filter { id($0.id).hasPrefix(key) }
    guard !key.isEmpty, hits.count == 1 else {
      throw Failure(hits.isEmpty ? "等你里没有 \(ref)：他可能已经答了或关掉了，看信封里的等你与变化" : "前缀 \(ref) 对上了 \(hits.count) 条：多写几位")
    }
    try await store.endCueQuestion(hits[0].id, .withdrawn)
    return hits[0]
  }

  // MARK: memory

  private func memory(_ args: Args) async throws -> Result {
    switch try args.required("action") {
    case "note":
      let (line, index) = try await store.noteCueLine(try args.required("text"), source: .cue, pinned: args.bool("pin") ?? false)
      return .ok("记下了 #\(index)\(line.pinned ? "，一直记着" : "")。", ["line": index, "id": id(line.id)])
    case "recall":
      let found = try await store.recallCue(try args.required("query"))
      var lines = found.lines.map { "#\($0.index) \($0.line.text)" + ($0.line.deletedAt == nil ? "" : "（已忘掉）") }
      lines += found.messages.map { "对话 \(iso($0.createdAt)) \($0.author.rawValue)：\(CueEnvelope.clip(CueFormat.plainText($0.text), 160))" }
      lines += found.cards.map { "\($0.isTask ? "任务" : "灵感")「\($0.heading)」（\($0.id.shortID)）" }
      return .ok(
        lines.isEmpty ? "没找到。" : lines.joined(separator: "\n"),
        ["lines": found.lines.map(\.index), "messages": found.messages.map { id($0.id) }, "cards": found.cards.map { id($0.id) }])
    case "forget":
      let (line, index) = try await line(args)
      try await store.forgetCueLine(line.id)
      return .ok("忘掉了 #\(index)。", ["line": index])
    case "pin":
      let (line, index) = try await line(args)
      guard let pinned = args.bool("pinned") else { throw Failure("pin 要给 pinned: true 或 false") }
      try await store.pinCueLine(line.id, pinned)
      return .ok(pinned ? "#\(index) 一直记着。" : "#\(index) 不再一直记着。", ["line": index, "pinned": pinned])
    case "remind":
      let raw = try args.required("at")
      guard let at = Self.date(raw) else { throw Failure("at 写 ISO 8601（2026-10-15T09:00:00+08:00）或 yyyy-MM-dd HH:mm（本机时区）") }
      guard at > Date() else { throw Failure("提醒时刻已经过了：\(raw)") }
      let (line, index) = try await store.noteCueLine(try args.required("text"), source: .cue, remindAt: at)
      return .ok("记下了 #\(index)，\(iso(at)) 叫醒你。", ["line": index, "id": id(line.id), "at": iso(at)])
    case "merge":
      guard let lo = args.int("lo"), let hi = args.int("hi") else { throw Failure("merge 要给 lo 与 hi（区间 [lo, hi)）") }
      try await store.setCueSummary(lo: lo, hi: hi, text: try args.required("text"))
      return .ok("#\(lo)-\(hi - 1) 合成了一行。", ["lo": lo, "hi": hi])
    case "renew":
      let message = try await store.addCueMessage(.handoff, text: try args.required("handoff"))
      return .ok("交接备忘写好了，接下来换新上下文。（\(message.id.shortID)）", ["message": id(message.id)])
    case let other: throw Failure("memory 没有 \(other)：可用 note / recall / forget / pin / remind / merge / renew")
    }
  }

  /// `line`：序号（可带 #）或 id。
  private func line(_ args: Args) async throws -> (CueMemoryLine, Int) {
    guard let raw = args.string("line") ?? args.int("line").map(String.init) else { throw Failure("要给 line（序号，如 12）") }
    let trimmed = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
    if let index = Int(trimmed), let line = try await store.cueLine(at: index) { return (line, index) }
    if let uuid = UUID(uuidString: raw), let line = try await store.cueLine(uuid), let index = try await store.cueLineIndex(uuid) { return (line, index) }
    throw Failure("没有记忆 \(raw)：用 recall 找它的序号")
  }

  static func date(_ raw: String) -> Date? {
    if let date = try? Date(raw, strategy: .iso8601) { return date }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss"] {
      formatter.dateFormat = format
      if let date = formatter.date(from: raw) { return date }
    }
    return nil
  }

  // MARK: 引用

  private func host() async throws -> String {
    guard let host = try await store.cueProfile()?.activeHost else { throw CueStoreError.cueNotEnabled }
    return host
  }

  private func project(_ ref: String) async throws -> Project {
    let all = try await store.projects()
    if let hit = all.first(where: { $0.name.caseInsensitiveCompare(ref) == .orderedSame || $0.id.uuidString.lowercased().hasPrefix(ref.lowercased()) && ref.count >= 4 }) {
      return hit
    }
    throw Failure("没有项目「\(ref)」。现有：" + (all.isEmpty ? "无" : all.map(\.name).joined(separator: "、")))
  }

  /// 任务：id、至少 4 位的 id 前缀，或标题（不分大小写，只在没删除的任务里找）。
  private func task(_ ref: String) async throws -> Card {
    let key = ref.trimmingCharacters(in: .whitespaces)
    if let uuid = UUID(uuidString: key), let card = try await store.card(uuid), card.isTask, card.deletedAt == nil { return card }
    if key.count >= 4, key.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
      let hits = try await store.cards(idPrefix: key).filter { $0.isTask && $0.deletedAt == nil }
      if hits.count == 1 { return hits[0] }
      if hits.count > 1 { throw Failure("前缀 \(key) 对上了 \(hits.count) 个任务：多写几位") }
    }
    let named = try await store.tasks(.todo, .inProgress, .done).flatMap(\.tasks).filter { $0.heading.caseInsensitiveCompare(key) == .orderedSame }
    if named.count == 1 { return named[0] }
    if named.count > 1 { throw Failure("有 \(named.count) 个任务叫「\(key)」：用 id（peek 里有）") }
    throw Failure("找不到任务「\(key)」：用 task peek 看看板上的 id")
  }

  /// 任务此刻在做的叶子（给顶层任务时是它在做的那个步骤）。
  private func workingLeaf(_ ref: String) async throws -> Card {
    try await store.workingLeaf(of: try await task(ref).id)
  }

  private func id(_ id: UUID) -> String { id.uuidString.lowercased() }
  private func iso(_ date: Date) -> String { date.formatted(.iso8601) }
}

/// 工具参数（JSON 对象）。
struct Args {
  let raw: [String: Any]

  func string(_ key: String) -> String? {
    guard let value = raw[key] as? String else { return nil }
    return value
  }

  func required(_ key: String) throws -> String {
    guard let value = string(key), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CueTools.Failure("缺少 \(key)")
    }
    return value
  }

  func strings(_ key: String) -> [String]? { raw[key] as? [String] }

  func bool(_ key: String) -> Bool? { (raw[key] as? NSNumber)?.boolValue }

  func int(_ key: String) -> Int? {
    if let number = raw[key] as? NSNumber { return number.intValue }
    return (raw[key] as? String).flatMap { Int($0) }
  }
}

extension Optional {
  func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
    guard let self else { return nil }
    return try await transform(self)
  }
}
