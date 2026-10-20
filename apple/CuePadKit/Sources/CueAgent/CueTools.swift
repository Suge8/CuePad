import CueStore
import CueText
import Foundation

/// Cue 的三个工具（task、tell、memory）：定义与实现。都经 `CueStore` 的业务操作，写出的投送请求与消息标明来自 Cue。
/// 返回一两句人话加 id，只有正文（三家大脑给模型看的都是这一份）；出错给出路（`isError`）。
public struct CueTools: Sendable {
  let store: CueStore
  /// 说话类请求写下后等结果多久（`Speech.cueWait`；测试给短的）。
  let wait: TimeInterval

  public init(store: CueStore, wait: TimeInterval = Speech.cueWait) {
    self.store = store
    self.wait = wait
  }

  /// 一次调用的结果（MCP 的 `CallToolResult`）。
  public struct Result: Sendable {
    public var text: String
    public var isError: Bool

    static func ok(_ text: String) -> Result { Result(text: text, isError: false) }
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
          任务与会话。task 写任务的 id 前缀或标题，session 写会话的 id 前缀或会话名（信封与 peek 里有）。body、text 里原样写的 ![](cuepad://img/<hash>) 作为图片交给会话。
          add{title,project?,steps?,body?,session?}：建任务。body 是正文，开工时连同标题作为会话的第一句（步骤开新会话时先带上顶层任务的标题与正文）；步骤自己的话用 edit 写在步骤上。同一项目里已有同名没做完的任务时不另建，返回那件。带 session 把那个会话绑到新任务上：不写 body（话用 say 说），project 缺省是会话所在的项目；
          edit{task,title?,body?,steps?,project?,reopen?}：改标题、换掉正文、追加步骤、连同步骤挪到项目；追加步骤与 reopen:true 都让已完成的任务回到没做完；
          start{task,agent?,model?,effort?,fresh?}：开工叶子（task 有步骤时是第一个没做完的步骤）。同一任务的上一步有会话就接着用它（已结束的先恢复），否则在项目文件夹开新会话：agent 缺省是那台 Mac 的默认，model 写 provider/id（claude、codex 只写 id）。叶子已有会话用 say；fresh:true 开新会话（上一步的会话随之结束）；
          say{task|session,text,model?,effort?}：对会话说话（给 task 是它在做的叶子的会话；结束了的先恢复）。会话在等回答时 text 就是答案（选项原文、从 1 起的序号或 是/否；允许自己写的题才收别的话）；否则会话在跑时打断这一轮、以这句开新一轮，他发起的那一轮在跑时不说（报错，歇下会叫醒你）。带 model、effort 先给会话换上；
          say 与接着用上一步会话的 start 等送达结果至多 \(Int(Speech.cueWait)) 秒：已送达、没送到（出错，带原因），或还没结果（之后没送到会作为 [发送失败] 叫醒你）；
          peek{task?|session?}：只读。都不带：所有没做完的事、不归没做完的事的活会话，和最近完成的几件（各带会话）。带 task：叶子、正文、近况、最近几轮问答（"他"是用户，"你"是你）与最新回答全文、发到手机的文件（带本机路径）。带 session：那个会话；
          stop{task|session}：停下会话这一轮；
          leave{task|session}：会话停着（歇下或等回答）、这次该他接手时用，把它留给他回：会话列表显示"待回复"（等回答的回到等他确认）；不用另外 tell，他或你再对它说话就作废；
          done{task|session,evidence?,show?}：做完。顶层任务要 evidence：1–\(evidenceCount) 条结论，每条宽不过 \(evidenceLimit)（约 20 个汉字，如"\(evidenceExample)"），CuePad 把标题与证据拼成结果告诉用户。show 是结果上挂的图，写法同 tell 的 show（如 look 写"最终版深色：分组标题"）；不带就不挂图，没点名的仍在会话里。下一步还用它的会话就留着，否则结束会话（结束的照样能 say）；已完成的再 done 只结束没人再用的会话，不要 evidence、show。给 session 是收掉那个会话：没做完的事在用、或有话正送进去的不收。
          """,
        "inputSchema": schema(
          [
            "action": ["type": "string", "enum": ["add", "edit", "start", "say", "peek", "stop", "leave", "done"]],
            "task": string, "session": string, "title": name, "project": string, "steps": ["type": "array", "items": name], "body": string,
            "agent": ["type": "string", "enum": AgentKind.allCases.map(\.rawValue)], "model": ["type": "string", "description": "provider/id"],
            "effort": ["type": "string", "enum": PiThinkingLevel.allCases.map(\.rawValue)], "text": string,
            "evidence": ["type": "array", "items": ["type": "string", "description": "宽不过 \(evidenceLimit)"], "maxItems": evidenceCount],
            "show": show, "fresh": ["type": "boolean"], "reopen": ["type": "boolean"],
          ], required: ["action"]),
        "annotations": ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false],
      ],
      [
        "name": "tell",
        "description": """
          对用户说一句（Cue 页里你的一行）。ask 是请他允许、等他回答（进"等你"），只能是这几类：\(CuePrompt.asks)。
          带 ask 必写 doing：一句说清要他定什么，动词开头写清对象，一行、≤\(CueAsking.phraseLimit) 字（如"推送 scheduler 的重连修复"；几个方案里挑时写你推荐的那个，如"按方案 1 决定单改提问卡"）；ask=rule 还必写 rule：依据他的哪条规矩，照他的原话（如"改数据库结构前先问我"）。
          卡片、摘要与通知只显示"可以<doing>吗？"、rule 那类的这条规矩、show 的图与选项，不显示 text。
          show 是回答这个问题必须看的图，至多 \(CueShot.limit) 张，按要他看的先后：file 写 task peek 里"发到手机的"那一份的 id，look 写这张看什么（一行、≤\(CueShot.lookLimit) 字，如"方案 1：大按钮占满一行"）。几个方案就每个方案一张、同一台设备同一种样子，推荐的在前；不用看图就能答的不带。只有 show 里的图上卡片。
          text 先一句要做的动作，再一句依据（rule 那类写哪条规矩）和不做会怎样；不写 push、rule 这类分类名。
          选项由 CuePad 给（如推送：\(CueAsk.push.choices(in: "项目名").joined(separator: " / "))；不带 task 时第二项是"\(CueAsk.push.always ?? "")"；rule 只有第一项），他选第二项就照字面记进允许清单。卡上只能选：他在 Cue 页一开口，开着的卡就当场收起，算他直接说了；他那句不是在答它，restore 放回。允许清单里有的（task 所在的项目或所有项目）会被拒：直接做。
          urgent 推送到手机；task 关联一个任务（按它的项目查允许清单）；withdraw 写"等你"里一条的 id，撤回它（你不用再问了，或他在会话里说了怎么办），可同时带 text 说明；restore 写他开口收起的那条的 id，放回"等你"。
          """,
        "inputSchema": schema(
          [
            "text": string, "ask": ["type": "string", "enum": CueAsk.allCases.map(\.rawValue)], "doing": string, "rule": string,
            "urgent": ["type": "boolean"], "task": string, "withdraw": string, "restore": string, "show": show,
          ],
          required: []),
        "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
      ],
      [
        "name": "memory",
        "description": """
          你的长期记忆，一行一条（≤\(CueMemoryLine.maxBytes) 字节），序号就是身份。note{text,pin?} 记一条，pin 一直记着（不 pin 的旧行会被并成摘要）；recall{query} 只读：全文找记忆、对话与任务；
          forget{line}；pin{line,pinned}；remind{text,at} 到点叫醒你（ISO 8601 或 yyyy-MM-dd HH:mm）；merge{lo,hi,text} 把待合并的块写成一行摘要；
          renew{handoff} 写交接备忘，然后换新上下文：只写你在管的事各自做到哪、下一步，和他之间没了结的事，至多 \(handoffLimit) 字；
          allow{ask,project?,allowed?} 改允许清单：ask 只能是 \(Self.allowable)，不带 project 是所有项目，allowed:false 去掉。
          """,
        "inputSchema": schema(
          [
            "action": ["type": "string", "enum": ["note", "recall", "forget", "pin", "remind", "merge", "renew", "allow"]],
            "text": string, "pin": ["type": "boolean"], "query": string, "line": ["type": ["string", "integer"]],
            "pinned": ["type": "boolean"], "at": string, "lo": ["type": "integer"], "hi": ["type": "integer"], "handoff": string,
            "ask": ["type": "string", "enum": CueAsk.allCases.filter { $0.always != nil }.map(\.rawValue)], "project": string,
            "allowed": ["type": "boolean"],
          ], required: ["action"]),
        "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
      ],
    ]
  }

  private static var string: [String: Any] { ["type": "string"] }
  /// 点名要他看的图（tell 的提问与 done 的结果共用）：发到手机的那一份的 id 与看什么。
  private static var show: [String: Any] {
    ["type": "array", "maxItems": CueShot.limit, "items": ["type": "object", "properties": ["file": string, "look": string], "required": ["file", "look"]]]
  }
  /// 能放进允许清单的几类（规矩那一类不能）。
  private static var allowable: String { CueAsk.allCases.filter { $0.always != nil }.map(\.rawValue).joined(separator: " / ") }
  private static var name: [String: Any] { ["type": "string", "description": "宽不过 \(CueName.limit)（汉字算 2）"] }

  /// done 的证据：至多这么多条，每条宽不过 `evidenceLimit`（`CueName.width`）。结果消息由 Store 拼（`CueReport.text`）。
  static let evidenceCount = 3
  static let evidenceLimit = 40
  /// 交接备忘至多这么多字：新上下文每次接上都带着它，在做的事信封里本来就有。
  static let handoffLimit = 600
  /// 证据的示例（工具说明与证据超长的报错共用）：一句行为上的结论。
  static let evidenceExample = "登录后进到首页"


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
      return Result(text: failure.message, isError: true)
    } catch {
      // Kit 里只有 Cue 会碰到的错误，文案本来就是写给 Cue 的（见 `CueStoreError`）
      return Result(text: (error as? LocalizedError)?.errorDescription ?? "\(error)", isError: true)
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
      if let ref = args.string("task") { return try await peek(try await task(ref)) }
      if let ref = args.string("session") { return try await peek(try await session(ref)) }
      return try await board()
    case "stop":
      let target = try await speaker(args)
      _ = try await store.stopSession(target.session, host: try await host(), cue: true)
      return .ok("已请\(target.label)停下这一轮。（\(target.short)）")
    case "leave":
      _ = try await host()  // 停用后不再替他判断谁接手
      let target = try await speaker(args)
      try await store.leaveToYou(target.session)
      return .ok("已把\(target.label)留给他回：会话列表上写着待回复，他或你再对它说话就作废。（\(target.short)）")
    case "done": return try await done(args)
    case let other: throw Failure("task 没有 \(other)：可用 add / edit / start / say / peek / stop / leave / done")
    }
  }

  /// 做完：Cue 按证据确认过就完成（`finishTask`）；顶层任务同时把结果告诉用户，所以要 evidence，结果上只挂 show 点名的图。已完成的只结束没人再用的会话。
  /// 给 session 是收掉那个会话（`CueStore.endIdleSession`）。
  private func done(_ args: Args) async throws -> Result {
    _ = try await host()  // 停用后不能再做完事
    if args.string("task") == nil, let ref = args.string("session") {
      let session = try await session(ref)
      let ended = try await store.endIdleSession(session.sessionID) != nil
      return .ok((ended ? "已请会话「\(session.title)」结束" : "会话「\(session.title)」早已结束") + "。（\(session.shortID)）")
    }
    let card = try await task(args.required("task"))
    let reports = card.parentID == nil && card.status != .done
    let evidence = reports ? try Self.evidence(args) : []
    let shots = try CueShot.checked(try await shots(args.raw["show"]))
    if !reports, !shots.isEmpty { throw Failure("show 只跟着做完顶层任务：步骤与已完成的不写结果，没写") }
    let (report, ends) = try await store.finishTask(card.id, evidence: evidence, shots: shots)
    let ended = ends.isEmpty ? "" : "，已请 \(ends.count) 个会话结束"
    if card.status == .done {
      return .ok("「\(card.heading)」（\(card.id.shortID)）早已完成" + (ends.isEmpty ? "，没有要结束的会话（还在用的、已结束的不动）。" : "\(ended)。"))
    }
    return .ok(
      "「\(card.heading)」（\(card.id.shortID)）完成了" + ended
        + (report.map { "；结果已告诉用户（\($0.id.shortID)）" + (shots.isEmpty ? "，没挂图。" : "，挂着你点名的 \(shots.count) 张。") } ?? "。"))
  }

  /// 证据（done 做完顶层任务时）：1–`evidenceCount` 条，每条宽不过 `evidenceLimit`；不合就整件退回，什么都不写。
  private static func evidence(_ args: Args) throws -> [String] {
    let items = (args.strings("evidence") ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    guard (1...evidenceCount).contains(items.count) else { throw Failure("evidence 写 1–\(evidenceCount) 条证据（字符串数组），每条一句结论") }
    if let long = items.first(where: { CueName.width($0) > evidenceLimit }) {
      throw Failure("证据「\(long)」宽 \(CueName.width(long))，每条上限 \(evidenceLimit)（约 20 个汉字），没写：只写结论，如\"\(evidenceExample)\"，过程不写")
    }
    return items
  }

  /// Cue 写的名字（标题、步骤名）：去掉首尾空白后不空、宽不过 `CueName.limit`。不合抛错，调用方在写任何东西之前查完。
  private static func name(_ raw: String, _ what: String) throws -> String {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw Failure("\(what)不能为空") }
    let width = CueName.width(name)
    guard width <= CueName.limit else {
      throw Failure("\(what)「\(name)」宽 \(width)，上限 \(CueName.limit)（约 12 个汉字），什么都没写：只留要做成的结果，细节写进 body")
    }
    return name
  }

  private func add(_ args: Args) async throws -> Result {
    let heading = try Self.name(try args.required("title"), "标题")
    let names = try (args.strings("steps") ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { try Self.name($0, "步骤") }
    let session = try await args.string("session").asyncMap(session)
    if session != nil, args.string("body") != nil { throw Failure("带 session 时不写 body：会话已经在做，话用 say 对它说") }
    if let session, let busy = try await store.tasks(boundTo: session.sessionID).first(where: { $0.task.piSessionID == session.sessionID && $0.task.status != .done }) {
      throw Failure("会话「\(session.title)」正在做「\(busy.task.heading)」（\(busy.task.id.shortID)）：同一件事接着做用 say 或给它 edit 加步骤")
    }
    // 没给 project：带会话的是会话所在的项目，其余进默认项目
    var project = try await args.string("project").asyncMap(project)
    if project == nil, let home = session?.projectID { project = try await store.projects().first { $0.id == home } }
    let projectID = project?.id ?? Project.defaultID
    // 同一件事建第二份（重试、同一轮里并发发出的两次 add）只会开出第二个会话：返回已有的那件
    if session == nil, let same = try await store.tasks(.todo, .inProgress).flatMap(\.tasks).first(where: {
      $0.parentID == nil && $0.projectID == projectID && $0.heading.caseInsensitiveCompare(heading) == .orderedSame
    }) {
      let dropped = args.string("body") != nil || !names.isEmpty ? "，这次的正文与步骤也没写（要改用 edit）" : ""
      return .ok("已有没做完的「\(same.heading)」（\(same.id.shortID)），没再建\(dropped)：同一件事接着用它。")
    }
    let top = try await store.createTask(CueLines.joined(title: heading, rest: args.string("body")), in: projectID)
    var steps: [UUID] = []
    for step in names { steps.append(try await store.createTask(step, under: top.id).id) }
    var text = "建好了「\(top.heading)」（\(top.id.shortID)）" + (steps.isEmpty ? "" : "，\(steps.count) 个步骤")
    if let session {
      let leaf = try await store.workingLeaf(of: top.id)
      try await store.bindSession(session.sessionID, to: leaf.id)
      text += "，" + (leaf.id == top.id ? "" : "「\(leaf.heading)」") + "绑上了会话「\(session.title)」"
    }
    text += "，在项目「\(try await store.project(projectID)?.name ?? "")」里。"
    return .ok(text)
  }

  private func edit(_ args: Args) async throws -> Result {
    let card = try await task(args.required("task"))
    // 先查完再写，免得标题、步骤改了一半才报错
    let heading = try args.string("title").map { try Self.name($0, "标题") }
    let steps = try args.strings("steps").map { try $0.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { try Self.name($0, "步骤") } }
    if steps != nil, card.parentID != nil { throw Failure("步骤只能加在顶层任务上：task 写它的顶层任务") }
    let reopen = args.bool("reopen") == true
    if reopen, card.status != .done { throw Failure("「\(card.heading)」没完成，不用改回") }
    var done: [String] = []
    if reopen {
      try await store.reopenTask(card.id)
      done.append("改回了没做完")
    }
    if let heading {
      try await store.updateCard(card.id) { $0.body = CueLines.joined(title: heading, rest: $0.rest) }
      done.append("改了标题")
    }
    if let body = args.string("body") {
      try await store.updateCard(card.id) { $0.rest = body }
      done.append("换了正文")
    }
    if let steps {
      let existing = Set(try await store.children(of: card.id).filter(\.isTask).map { $0.heading })
      var added = 0
      for step in steps where !existing.contains(step) {
        _ = try await store.createTask(step, under: card.id)
        added += 1
      }
      done.append("追加了 \(added) 个步骤")
    }
    if let ref = args.string("project") {
      let project = try await project(ref)
      let top = try await store.topTask(of: card.id)
      try await store.moveCard(top, to: .top(project: project.id), after: nil)
      done.append("连同步骤挪到了项目「\(project.name)」")
    }
    guard !done.isEmpty else { throw Failure("edit 至少给 title、body、steps、project、reopen 之一") }
    return .ok("「\(card.heading)」（\(card.id.shortID)）：\(done.joined(separator: "，"))。")
  }

  private func start(_ args: Args) async throws -> Result {
    let agent = try args.string("agent").map { raw -> AgentKind in
      guard let agent = AgentKind(rawValue: raw) else { throw Failure("agent 只能是 \(Self.agents)") }
      return agent
    }
    let leaf = try await workingLeaf(try args.required("task"))
    let request = try await store.startLeaf(
      leaf.id, agent: agent, fresh: args.bool("fresh") == true, model: args.string("model"), thinking: try Self.effort(args), host: try await host(), cue: true)
    if request.mode == .known(.start) { return .ok("已请 Mac 为「\(leaf.heading)」开新会话，正文作为第一句。（\(leaf.id.shortID)）") }
    return try await spoken(request, "「\(leaf.heading)」接着用上一步的会话，正文作为下一句（送到后这一步绑上它）", tail: leaf.id.shortID)
  }

  private static func effort(_ args: Args) throws -> PiThinkingLevel? {
    try args.string("effort").map { raw -> PiThinkingLevel in
      guard let level = PiThinkingLevel(rawValue: raw) else { throw Failure("effort 只能是 \(PiThinkingLevel.allCases.map(\.rawValue).joined(separator: " / "))") }
      return level
    }
  }

  /// `agent` 的取值。
  private static let agents = AgentKind.allCases.map(\.rawValue).joined(separator: " / ")

  private func say(_ args: Args) async throws -> Result {
    let target = try await speaker(args)
    let host = try await host()
    let config = try await config(args, of: target.session)
    let switched = config.map { "先换成 " + [$0.model.map { "\($0.provider)/\($0.id)" }, $0.thinking?.rawValue].compactMap { $0 }.joined(separator: " ") + "，再" } ?? ""
    let request = try await store.speak(
      try args.required("text"), to: target.session, card: target.card, config: config, host: host, cue: true)
    let what = request.mode == .known(.answer) ? "\(switched)回答\(target.label)的提问" : "\(switched)对\(target.label)说"
    return try await spoken(request, what, tail: target.short)
  }

  /// say、stop 对的会话：给 task 是它在做的叶子绑着的会话（带上叶子），给 session 是那个会话。`label` 是工具结果里对它的称呼。
  private func speaker(_ args: Args) async throws -> (session: String, card: UUID?, label: String, short: String) {
    if let ref = args.string("task") {
      let leaf = try await workingLeaf(ref)
      return (try await store.leafSession(leaf.id), leaf.id, "「\(leaf.heading)」的会话", leaf.id.shortID)
    }
    guard let ref = args.string("session") else { throw Failure("要给 task 或 session") }
    let session = try await session(ref)
    return (session.sessionID, nil, "会话「\(session.title)」", session.shortID)
  }

  /// 说的话写下后等结果，至多到写下后 `wait`：结果按说的话那条规则（`Speech`）读——已送达、没送到（工具结果标成出错，带 Mac 报的原因），
  /// 或还在路上（如实说还没送达；之后没送到会写进下一轮的变化，见 `CueChange.Kind.undelivered`）。`what` 是做了什么。
  private func spoken(_ request: DeliveryRequest, _ what: String, tail short: String) async throws -> Result {
    let latest = try await settled(request)
    let tail = "（\(short)）"
    switch Speech.trip(latest, at: .always()) {
    case .delivered:
      return .ok("\(what)：已送达。\(tail)")
    case .failed(let failure):
      let reason = if case .reported(let reason) = failure { reason } else { DeliveryRequest.unexplainedFailure }
      return Result(text: "\(what)：没送到——\(reason)\(tail) \(Self.undeliveredMark(request.id))", isError: true)
    case .sending:
      return .ok("\(what)：已发出，还没送达，结果会写进变化。\(tail)")
    }
  }

  /// 说的话没送到时写在工具结果末尾的请求标识。工具写出回应不等于 Cue 看到了（大脑可能正在这时没了）：值班的管理器在这一轮
  /// 好好做完时，从这一轮收到的出错工具结果里认出它们，记下已告诉 Cue（`CueStore.markCueTold`），别的失败照样进下一轮的变化。
  static func undeliveredMark(_ request: UUID) -> String { "[请求 \(request.uuidString.lowercased())]" }

  /// 一条出错的工具结果里告诉了 Cue 的没送到的请求（`undeliveredMark`）。
  public static func undeliveredRequests(in result: String) -> [UUID] {
    result.matches(of: /\[请求 ([0-9a-f-]{36})\]/).compactMap { UUID(uuidString: String($0.1)) }
  }

  /// 等请求有结果，至多到写下后 `wait`；到点还没结果返回此刻的记录。等的是别的进程（执行它的 Mac 上的 App）写回的结果：
  /// 库的变化订阅跨进程（`CueStore.outcome`），不轮询；到点用一次可取消的睡眠——等多久本身就是这里的规则。
  private func settled(_ request: DeliveryRequest) async throws -> DeliveryRequest {
    let left = request.createdAt.addingTimeInterval(wait).timeIntervalSinceNow
    let done = try await withThrowingTaskGroup(of: DeliveryRequest?.self) { group in
      group.addTask { [store] in try await store.outcome(of: request.id) }
      group.addTask {
        if left > 0 { try await Task.sleep(for: .seconds(left)) }
        return nil
      }
      defer { group.cancelAll() }
      return try await group.next() ?? nil
    }
    if let done { return done }
    return try await store.deliveryRequest(request.id) ?? request
  }

  /// say 带的 model、effort（说话与作答之前先换上）；model 的写法同 start，只写 id 时提供方按会话是哪家补。都没带为 nil。
  private func config(_ args: Args, of session: String) async throws -> PiConfig? {
    let effort = try Self.effort(args)
    guard let raw = args.string("model") else { return effort.map { PiConfig(thinking: $0) } }
    let agent = try await store.piSessions(sessionIDs: [session])[session]?.state.agent.known
    return PiConfig(model: try (agent ?? .pi).requiredModelKey(raw), thinking: effort)
  }

  /// 看板：所有没做完的顶层任务，按项目分组，再是不归没做完的事的活会话，至多 `overviewLimit` 行；在做的归 Cue 管，其余是用户手上的清单。
  /// 末尾是最近完成的 `recentlyDone` 件，各带会话与它此刻的状态：在旧会话上做别的事时从这里找（add 带 session）。
  private func board() async throws -> Result {
    let board = try await store.cueBoard()
    let left = try await store.cueState()?.left ?? []
    let recent = try await store.cueRecentlyDone(limit: Self.recentlyDone)
    let items = board.tasks
    let names = Dictionary(uniqueKeysWithValues: try await store.projects().map { ($0.id, $0.name) })
    let now = Date()
    var lines: [(text: String, isItem: Bool)] = [], group: UUID?
    for item in items {
      if item.task.projectID != group {
        group = item.task.projectID
        lines.append(((names[item.task.projectID] ?? "") + "：", false))
      }
      lines.append(("- " + CueEnvelope.boardLine(item, now: now, left: left), true))
    }
    if !board.sessions.isEmpty {
      lines.append(("不归没做完的事的会话：", false))
      lines += board.sessions.map { ("- " + CueEnvelope.sessionLine($0, now: now, left: left), true) }
    }
    let total = items.count + board.sessions.count
    let room = Self.overviewLimit - 1 - (recent.isEmpty ? 0 : recent.count + 1)  // 第一行是"没做完的 N 件"，最近完成的总在末尾
    if lines.count > room {
      lines = Array(lines.prefix(room - 1))
      if lines.last?.isItem == false { lines.removeLast() }
      lines.append(("还有 \(total - lines.filter(\.isItem).count) 件", false))
    }
    if !recent.isEmpty {
      lines.append(("最近完成的（会话还能接着用：在它上面做别的事用 add 带 session）：", false))
      lines += recent.map { ("- \($0.task.heading)（\($0.task.id.shortID)） · " + CueEnvelope.sessionLine($0.session, now: now), true) }
    }
    return .ok(
      (total == 0 ? "没有没做完的事。" : "没做完的 \(total) 件，在做 \(items.count(where: \.isActive) + board.sessions.count) 件：")
        + (lines.isEmpty ? "" : "\n" + lines.map(\.text).joined(separator: "\n")))
  }

  /// 不带参数的 peek 末尾列几件最近完成的。
  static let recentlyDone = 5

  /// peek 里每个叶子最新的那条回答最多给这么多字。
  static let latestReplyLimit = 4000

  /// 不带 task 的 peek 的文字最多这么多行（含开头一行、项目名与"还有 N 件"）。
  static let overviewLimit = 60

  /// 会话是哪家 Agent 的（本版本不认识的写 Agent）。
  private static func agentName(_ session: PiSessionState) -> String { session.agent.known?.name ?? "Agent" }

  private func peek(_ card: Card) async throws -> Result {
    let detail = try await store.cueTaskDetail(card.id)
    let now = Date(), left = try await store.cueState()?.left ?? []
    var lines = [
      "「\(detail.task.heading)」（\(detail.task.id.shortID)）" + (detail.progress.map { " · 步骤 \($0.done)/\($0.total)" } ?? "")
        + " · " + status(detail.task)
    ]
    for leaf in detail.leaves {
      var head = leaf.leaf.id == detail.task.id ? "-" : "- 「\(leaf.leaf.heading)」（\(leaf.leaf.id.shortID)）\(status(leaf.leaf))"
      if let session = leaf.session {
        head += " · " + Self.sessionHead(session.session, now: now, left: left)
      } else {
        head += leaf.sending ? " · 发送中（话正送进上一步的会话）" : " · 没有会话"
      }
      lines.append(head)
      if let session = leaf.session { lines += Self.subagentLines(session.session, now: now) }
      if let rest = leaf.leaf.rest { lines.append("  正文：\(CueEnvelope.clip(CueFormat.plainText(rest), 200))") }
      if let session = leaf.session { lines += Self.conversation(session) }
    }
    lines += deliveredLines(try await store.deliverables(of: detail.task.id))
    return .ok(lines.joined(separator: "\n"))
  }

  private func peek(_ session: PiSessionState) async throws -> Result {
    guard let detail = try await store.cueSessionDetail(session.sessionID) else { throw Failure("找不到会话「\(session.title)」") }
    let bound = try await store.tasks(boundTo: session.sessionID)
    let left = try await store.cueState()?.left ?? []
    var lines = ["会话「\(session.title)」（\(session.shortID)）· " + Self.sessionHead(detail.session, now: Date(), left: left)]
    lines.append(
      bound.isEmpty ? "没绑任务（要为它的结果负责时用 add 带 session）"
        : "绑着：" + bound.map { "「\($0.task.heading)」（\($0.task.id.shortID)）\(status($0.task))" }.joined(separator: "、"))
    lines += Self.subagentLines(detail.session, now: Date())
    lines += Self.conversation(detail)
    lines += deliveredLines(try await store.previews(of: session.sessionID))
    return .ok(lines.joined(separator: "\n"))
  }

  /// 发到手机的文件，每份一行：id（提问与做完的 show 照它点名）、标题、类型、发来的时刻与本机路径（读文件工具按扩展名认类型，给的是按原文件名放的那份）。
  private func deliveredLines(_ previews: [PiPreview]) -> [String] {
    guard !previews.isEmpty else { return [] }
    return ["发到手机的（id，图片、PDF 用 read 打开）："] + previews.map { preview in
      "  - \(preview.id.shortID) 「\(preview.title)」\(preview.kind?.label ?? preview.name) · \(Self.clock(preview.createdAt)) · "
        + (store.files.url(of: preview)?.path ?? "还没同步到这台 Mac")
    }
  }

  /// 发来的时刻写成"10-17 15:34"（同信封的 24 小时制）。
  private static func clock(_ date: Date) -> String {
    date.formatted(.verbatim("\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)", timeZone: .current, calendar: .current))
  }

  /// 会话那一段：哪家、名字、状态与多久、在等的提问。
  private static func sessionHead(_ session: PiSessionState, now: Date, left: [CueLeft]) -> String {
    var head = "\(agentName(session))会话「\(session.title)」\(CueEnvelope.state(session.state)) \(CueEnvelope.duration(now.timeIntervalSince(session.stateSince)))"
    if left.contains(where: { $0.holds(for: session) }) { head += " · " + CueEnvelope.leftNote }
    if let question = session.question {
      head += " · 提问：\(CueEnvelope.clip(question.text, 120))" + (question.options.isEmpty ? "" : "（\(question.options.joined(separator: " / "))）")
    }
    return head
  }

  /// 会话带的子代理此刻怎样，每个一行、缩进两格：名册是 Agent 报给 Mac 的（FireCode 的名册、Claude Code 的后台任务……），
  /// 主会话嘴上说在等的，照这里看是不是真在等。
  private static func subagentLines(_ session: PiSessionState, now: Date) -> [String] {
    guard !session.subagents.isEmpty else { return [] }
    let running = session.subagents.count(where: \.isRunning)
    return ["  子代理 \(session.subagents.count) 个，" + (running == 0 ? "都不在跑：" : "\(running) 个在跑：")]
      + session.subagents.map { agent in
        "  - \(agent.name)：\(subagentPhase(agent, now: now))" + (agent.action.isEmpty ? "" : "「\(CueEnvelope.clip(agent.action, 120))」")
      }
  }

  private static func subagentPhase(_ agent: PiSubagentState, now: Date) -> String {
    let settled = agent.settledAt.map { " \(clock($0))" } ?? ""
    return switch agent.phase.known {
    case .running: "在跑" + (agent.progressAt.map { now.timeIntervalSince($0) >= 60 ? "，\(CueEnvelope.duration(now.timeIntervalSince($0)))没动静" : "" } ?? "")
    case .review: "在被审查"
    case .done: "交回了" + settled
    case .failed: "失败了" + settled
    case .interrupted: "被停下" + settled
    case .idle: "歇着"
    case nil: agent.phase.rawValue
    }
  }

  /// 会话最近几轮问答（最新的回答给全文，常是测试输出与证据，更早的截短），每行缩进两格。
  private static func conversation(_ detail: CueSessionDetail) -> [String] {
    var lines: [String] = []
    let latest = detail.recent.lastIndex { $0.role == .known(.pi) }
    let agent = agentName(detail.session)
    for (index, message) in detail.recent.enumerated() {
      let text = CueFormat.plainText(message.text)
      guard index == latest else {
        let who = message.role == .known(.pi) ? agent : message.saidByCue(detail.cueSent) ? "你" : "他"
        lines.append("  \(who)：\(CueEnvelope.clip(text, 300))")
        continue
      }
      let full = text.count > latestReplyLimit
        ? String(text.prefix(latestReplyLimit)) + "\n（后面还有 \(text.count - latestReplyLimit) 字，截掉了）" : text
      lines.append("  \(agent)（最新的回答）：\n" + full.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n"))
    }
    return lines
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

  /// 先撤回（若有 withdraw）、放回（若有 restore），再说（若有 text）；都没有是参数错。
  private func tell(_ args: Args) async throws -> Result {
    let related = try await args.string("task").asyncMap(task)
    let shots = try CueShot.checked(try await shots(args.raw["show"]))
    let ask = try args.string("ask").map { raw -> CueAsking in
      guard let ask = CueAsk(rawValue: raw) else { throw Failure("ask 只能是这几类：\(CuePrompt.asks)；别的事你自己定，做完告诉他") }
      return try CueAsking(ask, action: args.string("doing"), rule: args.string("rule"))
    }
    if ask == nil, !shots.isEmpty { throw Failure("show 只跟着 ask：要他看的图放在提问上") }
    var done: [String] = []
    if let ref = args.string("withdraw") {
      let question = try await question(ref, in: store.cueMessagesWaitingForYou(), missing: "等你里没有 \(ref)：他可能已经答了，看信封里的等你")
      try await store.endCueQuestion(question.id, .withdrawn)
      done.append("已撤回「\(CueEnvelope.clip(CueFormat.plainText(question.text), 40))」。")
    }
    if let ref = args.string("restore") {
      let question = try await question(ref, in: store.cueQuestionsSetAside(), missing: "他开口收起的里没有 \(ref)：照他那句话后面列的 id 写")
      try await store.restoreCueQuestion(question.id)
      done.append("已放回「\(CueEnvelope.clip(CueFormat.plainText(question.text), 40))」。")
    }
    guard let text = args.string("text") else {
      guard !done.isEmpty else { throw Failure("要给 text（说什么）、withdraw（撤回哪条提问）或 restore（放回哪条）") }
      return .ok(done.joined())
    }
    let message = try await store.addCueMessage(.cue, text: text, ask: ask, shots: shots, urgent: args.bool("urgent") ?? false, task: related?.id)
    return .ok(done.joined() + (message.choices != nil ? "已问用户，等他选。" : "已告诉用户。") + "（\(message.id.shortID)）")
  }

  /// show 点名的图（tell 的提问、done 的结果）：每张的 file 是发到手机的那一份的 id 或前缀（task peek 里列的）。
  private func shots(_ raw: Any?) async throws -> [CueShot] {
    guard let raw else { return [] }
    guard let items = raw as? [[String: Any]] else { throw Failure("show 是数组：[{file, look}]") }
    var shots: [CueShot] = []
    for item in items {
      let key = (item["file"] as? String ?? "").trimmingCharacters(in: .whitespaces)
      let hits = key.isEmpty ? [] : try await store.previews(idPrefix: key)
      guard hits.count == 1 else {
        throw Failure(hits.isEmpty ? "发到手机的里没有 \(key)：照 task peek 里列的 id 写" : "前缀 \(key) 对上了 \(hits.count) 份：多写几位")
      }
      shots.append(CueShot(preview: hits[0].id, look: item["look"] as? String ?? ""))
    }
    return shots
  }

  /// `candidates` 里 id 或前缀是 `ref` 的那一条提问。
  private func question(_ ref: String, in candidates: [CueMessage], missing: String) throws -> CueMessage {
    let key = ref.trimmingCharacters(in: .whitespaces).lowercased()
    let hits = candidates.filter { id($0.id).hasPrefix(key) }
    guard !key.isEmpty, hits.count == 1 else { throw Failure(hits.isEmpty ? missing : "前缀 \(ref) 对上了 \(hits.count) 条：多写几位") }
    return hits[0]
  }

  // MARK: memory

  private func memory(_ args: Args) async throws -> Result {
    switch try args.required("action") {
    case "note":
      let (line, index) = try await store.noteCueLine(try args.required("text"), source: .cue, pinned: args.bool("pin") ?? false)
      return .ok("记下了 #\(index)\(line.pinned ? "，一直记着" : "")。")
    case "recall":
      let found = try await store.recallCue(try args.required("query"))
      var lines = found.lines.map { "#\($0.index) \($0.line.text)" + ($0.line.deletedAt == nil ? "" : "（已忘掉）") }
      lines += found.messages.map { "对话 \(iso($0.createdAt)) \($0.author.rawValue)：\(CueEnvelope.clip(CueFormat.plainText($0.text), 160))" }
      lines += found.cards.map { "\($0.isTask ? "任务" : "灵感")「\($0.heading)」（\($0.id.shortID)）" }
      return .ok(lines.isEmpty ? "没找到。" : lines.joined(separator: "\n"))
    case "forget":
      let (line, index) = try await line(args)
      try await store.forgetCueLine(line.id)
      return .ok("忘掉了 #\(index)。")
    case "pin":
      let (line, index) = try await line(args)
      guard let pinned = args.bool("pinned") else { throw Failure("pin 要给 pinned: true 或 false") }
      try await store.pinCueLine(line.id, pinned)
      return .ok(pinned ? "#\(index) 一直记着。" : "#\(index) 不再一直记着。")
    case "remind":
      let raw = try args.required("at")
      guard let at = Self.date(raw) else { throw Failure("at 写 ISO 8601（2026-10-15T09:00:00+08:00）或 yyyy-MM-dd HH:mm（本机时区）") }
      guard at > Date() else { throw Failure("提醒时刻已经过了：\(raw)") }
      let (_, index) = try await store.noteCueLine(try args.required("text"), source: .cue, remindAt: at)
      return .ok("记下了 #\(index)，\(iso(at)) 叫醒你。")
    case "merge":
      guard let lo = args.int("lo"), let hi = args.int("hi") else { throw Failure("merge 要给 lo 与 hi（区间 [lo, hi)）") }
      try await store.setCueSummary(lo: lo, hi: hi, text: try args.required("text"))
      return .ok("#\(lo)-\(hi - 1) 合成了一行。")
    case "renew":
      let handoff = try args.required("handoff")
      guard handoff.count <= Self.handoffLimit else {
        throw Failure("交接 \(handoff.count) 字，上限 \(Self.handoffLimit)，没写：只写你在管的事各自做到哪、下一步，和他之间没了结的事，每件一两句")
      }
      let message = try await store.addCueMessage(.handoff, text: handoff)
      return .ok("交接备忘写好了，接下来换新上下文。（\(message.id.shortID)）")
    case "allow": return try await allow(args)
    case let other: throw Failure("memory 没有 \(other)：可用 note / recall / forget / pin / remind / merge / renew / allow")
    }
  }

  /// 改允许清单（`CueStore.setCueAllow`）：这类事在一个项目或所有项目里以后不用问，或去掉。
  private func allow(_ args: Args) async throws -> Result {
    let raw = try args.required("ask")
    guard let ask = CueAsk(rawValue: raw), ask.always != nil else { throw Failure("ask 只能是 \(Self.allowable)：规矩那一类不能放行") }
    let project = try await args.string("project").asyncMap(project)
    let allowed = args.bool("allowed") ?? true
    let changed = try await store.setCueAllow(CueAllow(ask, project: project?.id), allowed: allowed)
    let scope = project.map { "项目「\($0.name)」里" } ?? "所有项目里"
    let what = "\(scope)\(ask.name)" + (allowed ? "以后不用问" : "又要先问")
    return .ok((changed ? "记下了：" : "本来就是：") + what + "。")
  }

  /// `line`：序号（可带 #）或 id。
  private func line(_ args: Args) async throws -> (CueMemoryLine, Int) {
    guard let raw = args.string("line") ?? args.int("line").map(String.init) else { throw Failure("要给 line（序号，如 12）") }
    let trimmed = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
    if let index = Int(trimmed), let line = try await store.cueLine(at: index) { return (line, index) }
    if let uuid = UUID(uuidString: raw), let line = try await store.cueLine(uuid), let index = try await store.cueLineIndex(uuid) { return (line, index) }
    throw Failure("没有记忆 \(raw)：用 recall 找它的序号")
  }

  private static func date(_ raw: String) -> Date? {
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
  func task(_ ref: String) async throws -> Card {
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

  /// 会话：会话 id 至少 4 位的前缀或会话名（`CueStore.sessions(matching:)`）；同名的几个里只有一个没结束就是它。
  private func session(_ ref: String) async throws -> PiSessionState {
    let hits = try await store.sessions(matching: ref)
    let live = hits.filter { $0.state != .known(.ended) }
    if hits.count == 1 { return hits[0] }
    if live.count == 1 { return live[0] }
    if hits.isEmpty { throw Failure("找不到会话「\(ref)」：用 task peek 看会话的 id") }
    throw Failure("「\(ref)」对上了 \(hits.count) 个会话：用会话 id（peek 里有）")
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

  func string(_ key: String) -> String? { raw[key] as? String }

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
