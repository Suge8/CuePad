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
          add{title,project?,steps?,prompt?} 建任务，默认由你跟进；edit{task,title?,prompt?,steps?} 改标题、草稿或追加步骤；
          start{task,agent?,model?,effort?} 开工：叶子绑着会话就把草稿发进去，没绑就在项目文件夹开新会话；
          say{task,text,when:now|after|answer,value?} 对叶子的会话说话（now 马上说，after 等它做完，answer 回答它的提问，value 是选项或 yes/no）；
          peek{task?} 只读：不带 task 看看板，带 task 看叶子、近况、最近几轮问答与预览；
          stop{task} 停下这一轮；done{task} 完成叶子并结束会话；follow{task,who:cue|you} 换人跟进。
          """,
        "inputSchema": schema(
          [
            "action": ["type": "string", "enum": ["add", "edit", "start", "say", "peek", "stop", "done", "follow"]],
            "task": string, "title": string, "project": string, "steps": ["type": "array", "items": string], "prompt": string,
            "agent": ["type": "string", "enum": ["pi"]], "model": ["type": "string", "description": "provider/id"],
            "effort": ["type": "string", "enum": PiThinkingLevel.allCases.map(\.rawValue)], "text": string,
            "when": ["type": "string", "enum": ["now", "after", "answer"]], "value": string,
            "who": ["type": "string", "enum": ["cue", "you"]],
          ], required: ["action"]),
        "annotations": ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false],
      ],
      [
        "name": "tell",
        "description": "对用户说一句（Cue 页里你的一行）。带 choices 就是在等用户选；urgent 推送到手机，只用在真要他马上看的事；task 关联到一个任务。",
        "inputSchema": schema(
          ["text": string, "choices": ["type": "array", "items": string], "urgent": ["type": "boolean"], "task": string],
          required: ["text"]),
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
      return Result(text: Self.describe(error), structured: [:], isError: true)
    }
  }

  private static func describe(_ error: any Error) -> String {
    switch error as? CueStoreError {
    case .notALeaf: "这件事有步骤，会话在步骤上：task 写具体步骤"
    case .sessionBusy: "会话正在做事：say 用 when=now 马上说，或 when=after 等它做完"
    case .noSession(let title): "「\(title)」还没有会话：先 task start（草稿作为第一句）"
    case .noFolder(let project):
      project.isEmpty ? "这件事不在项目里，没有文件夹开会话：用 tell 请用户把它放进一个绑了文件夹的项目" : "项目「\(project)」没绑文件夹：用 tell 请用户在 CuePad 里给它绑一个"
    case .nothingToAnswer: "会话此刻没有等回答的提问：用 say when=now 或 after 说话"
    case .launching(let title): "正在为「\(title)」开会话：等它开好（peek 看状态），再用 say 说话"
    case let error?: error.localizedDescription
    case nil: (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
  }

  // MARK: task

  private func task(_ args: Args) async throws -> Result {
    switch try args.required("action") {
    case "add": return try await add(args)
    case "edit": return try await edit(args)
    case "start": return try await start(args)
    case "say": return try await say(args)
    case "peek": return try await args.string("task") == nil ? board() : peek(try await task(args.required("task")))
    case "stop":
      let leaf = try await workingLeaf(try args.required("task"))
      let request = try await store.stopLeaf(leaf.id, host: try await host(), cue: true)
      return .ok("已请会话停下这一轮：「\(title(leaf))」（\(short(leaf.id))）。", ["task": id(leaf.id), "request": id(request.id)])
    case "done":
      let leaf = try await task(args.required("task"))
      let end = try await store.completeLeaf(leaf.id, host: try await host(), cue: true)
      return .ok(
        "「\(title(leaf))」（\(short(leaf.id))）完成了" + (end == nil ? "。" : "，已请会话结束。"),
        ["task": id(leaf.id), "request": end.map { id($0.id) } ?? NSNull()])
    case "follow":
      let who = try args.required("who")
      guard ["cue", "you"].contains(who) else { throw Failure("who 只能是 cue 或 you") }
      let top = try await store.setCueFollows(try await task(args.required("task")).id, who == "cue")
      return .ok("「\(title(top))」（\(short(top.id))）" + (who == "cue" ? "由你跟进。" : "交还给用户，不再跟进。"), ["task": id(top.id), "follows": who == "cue"])
    case let other: throw Failure("task 没有 \(other)：可用 add / edit / start / say / peek / stop / done / follow")
    }
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
    var text = "建好了「\(title(top))」（\(short(top.id))）" + (steps.isEmpty ? "" : "，\(steps.count) 个步骤")
    var prompt: UUID?
    if let body = args.string("prompt") {
      let draft = try await store.createCard(body: body, under: top.id)
      prompt = draft.id
      let leaf = try await store.workingLeaf(of: top.id)
      text += leaf.id == top.id ? "，带着草稿" : "，草稿在「\(title(leaf))」上"
    }
    text += project == nil ? "（未分类：开不了会话，要开工先请用户放进项目）。" : "，在项目「\(project!.name)」里，由你跟进。"
    return .ok(text, ["task": id(top.id), "steps": steps.map(id), "prompt": prompt.map(id) ?? NSNull()])
  }

  private func edit(_ args: Args) async throws -> Result {
    let card = try await task(args.required("task"))
    var done: [String] = []
    if let heading = args.string("title") {
      guard !heading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure("标题不能为空") }
      try await store.updateCard(card.id) { $0.body = heading }
      done.append("改了标题")
    }
    if let steps = args.strings("steps") {
      guard card.parentID == nil else { throw Failure("步骤只能加在顶层任务上：task 写它的顶层任务") }
      let existing = Set(try await store.children(of: card.id).filter(\.isTask).map { title($0) })
      var added = 0
      for step in steps where !step.isEmpty && !existing.contains(step) {
        _ = try await store.createTask(step, under: card.id)
        added += 1
      }
      done.append("追加了 \(added) 个步骤")
    }
    if let body = args.string("prompt") {
      let leaf = try await store.workingLeaf(of: card.id)
      if let draft = try await store.cueTaskDetail(leaf.id).leaves.first(where: { $0.leaf.id == leaf.id })?.draft {
        try await store.updateCard(draft.id) { $0.body = body }
      } else {
        _ = try await store.createCard(body: body, under: leaf.id)
      }
      done.append("草稿写在「\(title(leaf))」上")
    }
    guard !done.isEmpty else { throw Failure("edit 至少给 title、prompt、steps 之一") }
    return .ok("「\(title(card))」（\(short(card.id))）：\(done.joined(separator: "，"))。", ["task": id(card.id)])
  }

  private func start(_ args: Args) async throws -> Result {
    if let agent = args.string("agent"), agent != "pi" { throw Failure("目前只能开 Pi 会话（agent 省略或写 pi）") }
    let leaf = try await workingLeaf(try args.required("task"))
    let detail = try await store.cueTaskDetail(leaf.id).leaves.first { $0.leaf.id == leaf.id }
    if leaf.piSessionID != nil, detail?.draft == nil { throw Failure("「\(title(leaf))」已有会话：用 say 对它说话") }
    let model = try args.string("model").map { ref -> PiModelKey in
      let parts = ref.split(separator: "/", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { throw Failure("model 写成 provider/id：提供方与模型 id 用 / 隔开") }
      return PiModelKey(provider: parts[0], id: parts[1])
    }
    let effort = try args.string("effort").map { raw -> PiThinkingLevel in
      guard let level = PiThinkingLevel(rawValue: raw) else { throw Failure("effort 只能是 \(PiThinkingLevel.allCases.map(\.rawValue).joined(separator: " / "))") }
      return level
    }
    let result = try await store.handOff(leaf.id, model: model, thinking: effort, host: try await host(), cue: true)
    let text: String =
      switch result {
      case .sent: "草稿已发进「\(title(leaf))」的会话。"
      case .started: "已请 Mac 为「\(title(leaf))」开新会话" + (detail?.draft == nil ? "（没有草稿，开好后用 say 说第一句）。" : "，草稿作为第一句。")
      }
    return .ok(text + "（\(short(leaf.id))）", ["task": id(leaf.id), "request": id(result.request.id), "started": { if case .started = result { true } else { false } }()])
  }

  private func say(_ args: Args) async throws -> Result {
    let leaf = try await workingLeaf(try args.required("task"))
    let host = try await host()
    let when = args.string("when") ?? "now"
    if when == "answer" {
      guard let value = args.string("value") ?? args.string("text") else { throw Failure("answer 要给 value（选项原文、序号或 yes/no）") }
      let request = try await store.answerLeaf(leaf.id, value, host: host, cue: true)
      return .ok("已回答「\(title(leaf))」的提问：\(value)", ["task": id(leaf.id), "request": id(request.id)])
    }
    guard ["now", "after"].contains(when) else { throw Failure("when 只能是 now、after 或 answer") }
    let text = try args.required("text")
    if leaf.piSessionID == nil {
      if try await !store.launchingCards([leaf.id]).isEmpty { throw CueStoreError.launching(title(leaf)) }
      throw Failure("「\(title(leaf))」还没有会话：先用 edit 写草稿再 start，草稿会作为第一句")
    }
    let request: DeliveryRequest
    do {
      request = try await store.handOff(leaf.id, text: text, host: host, cue: true).request
    } catch CueStoreError.sessionBusy {
      request = try await store.handOff(leaf.id, text: text, mode: when == "now" ? .steer : .followUp, host: host, cue: true).request
    }
    let how = request.mode == .known(.steer) ? "（会话正忙，马上说）" : request.mode == .known(.followUp) ? "（会话正忙，等它做完再说）" : ""
    return .ok("已对「\(title(leaf))」的会话说了\(how)。（\(short(leaf.id))）", ["task": id(leaf.id), "request": id(request.id), "mode": request.mode.rawValue])
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
            "id": id(item.task.id), "title": title(item.task), "leaf": id(item.leaf.id),
            "progress": item.progress.map { ["done": $0.done, "total": $0.total] as [String: Any] } ?? NSNull(),
            "session": item.session?.sessionID ?? NSNull(), "state": item.session?.state.rawValue ?? NSNull(),
            "launching": item.launching, "since": iso(item.since),
          ]
        }
      ])
  }

  private func peek(_ card: Card) async throws -> Result {
    let detail = try await store.cueTaskDetail(card.id)
    let now = Date()
    var lines = [
      "「\(title(detail.task))」（\(short(detail.task.id))）" + (detail.progress.map { " · 步骤 \($0.done)/\($0.total)" } ?? "")
        + " · " + (detail.task.cueFollows ? "由你跟进" : "用户自己做") + " · " + status(detail.task)
    ]
    for leaf in detail.leaves {
      var head = leaf.leaf.id == detail.task.id ? "-" : "- 「\(title(leaf.leaf))」（\(short(leaf.leaf.id))）\(status(leaf.leaf))"
      if let session = leaf.session {
        head += " · 会话「\(session.title)」\(CueEnvelope.state(session.state)) \(CueEnvelope.duration(now.timeIntervalSince(session.stateSince)))"
        if let question = session.question { head += " · 提问：\(CueEnvelope.clip(question.text, 120))" + (question.options.isEmpty ? "" : "（\(question.options.joined(separator: " / "))）") }
      } else {
        head += " · 没有会话"
      }
      lines.append(head)
      if let draft = leaf.draft { lines.append("  草稿：\(CueEnvelope.clip(CueFormat.plainText(draft.body), 200))") }
      for message in leaf.recent {
        let who = message.role == .known(.user) ? "你" : "Pi"
        lines.append("  \(who)：\(CueEnvelope.clip(CueFormat.plainText(message.text), 300))")
      }
      if !leaf.previews.isEmpty { lines.append("  预览：" + leaf.previews.map(\.name).joined(separator: "、")) }
    }
    return .ok(
      lines.joined(separator: "\n"),
      [
        "task": id(detail.task.id), "follows": detail.task.cueFollows,
        "leaves": detail.leaves.map { leaf -> [String: Any] in
          [
            "id": id(leaf.leaf.id), "title": title(leaf.leaf), "status": leaf.leaf.status?.rawValue ?? NSNull(),
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

  private func tell(_ args: Args) async throws -> Result {
    let text = try args.required("text")
    let related = try await args.string("task").asyncMap(task)
    let message = try await store.addCueMessage(
      .cue, text: text, choices: args.strings("choices"), urgent: args.bool("urgent") ?? false, task: related?.id)
    let waits = message.choices != nil
    return .ok(
      (waits ? "已问用户，等他选。" : "已告诉用户。") + "（\(short(message.id))）",
      ["message": id(message.id), "waiting": waits])
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
      lines += found.cards.map { "\($0.isTask ? "任务" : "灵感")「\(title($0))」（\(short($0.id))）" }
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
      return .ok("交接备忘写好了，接下来换新上下文。（\(short(message.id))）", ["message": id(message.id)])
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
    guard let host = try await store.cueProfile()?.hostID else { throw Failure("Cue 还没选住在哪台 Mac，派不了活：请用户在 CuePad 里启用 Cue") }
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
    let named = try await store.tasks(.todo, .inProgress, .done).flatMap(\.tasks).filter { title($0).caseInsensitiveCompare(key) == .orderedSame }
    if named.count == 1 { return named[0] }
    if named.count > 1 { throw Failure("有 \(named.count) 个任务叫「\(key)」：用 id（peek 里有）") }
    throw Failure("找不到任务「\(key)」：用 task peek 看看板上的 id")
  }

  /// 任务此刻在做的叶子（给顶层任务时是它在做的那个步骤）。
  private func workingLeaf(_ ref: String) async throws -> Card {
    try await store.workingLeaf(of: try await task(ref).id)
  }

  private func title(_ card: Card) -> String { CueEnvelope.title(card) }
  private func short(_ id: UUID) -> String { CueEnvelope.short(id) }
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
