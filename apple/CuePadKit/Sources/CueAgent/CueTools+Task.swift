import CueStore
import CueText
import Foundation

extension CueTools {
  func task(_ args: Args) async throws -> Result {
    let rawAction = try args.required("action")
    guard let action = TaskAction(rawValue: rawAction) else {
      throw Failure("task 没有 \(rawAction)：可用 \(TaskAction.allCases.map(\.rawValue).joined(separator: " / "))")
    }
    let allowed: Set<String>?
    switch action {
    case .bind: allowed = ["action", "task", "session"]
    case .unbind: allowed = ["action", "task"]
    default: allowed = nil
    }
    if action == .start, args.string("session") != nil {
      throw Failure("start 不支持 session：关联已有会话用 bind")
    }
    if let allowed, let unsupported = args.raw.keys.filter({ !allowed.contains($0) }).sorted().first {
      throw Failure("\(action.rawValue) 不支持参数 \(unsupported)：关联已有会话用 bind，开工用 start")
    }
    switch action {
    case .add: return try await add(args)
    case .edit: return try await edit(args)
    case .start: return try await start(args)
    case .bind:
      let card = try await references.task(args.required("task"))
      let ref = try args.required("session")
      guard case .session(let session) = try await references.sessionRef(ref) else { throw Failure("bind 的 session 要写会话 id 或会话名") }
      try await store.bindSession(session.sessionID, to: card.id)
      return .ok("已把「\(card.heading)」关联到会话「\(session.title)」。（\(card.id.shortID)）")
    case .unbind:
      let card = try await references.task(args.required("task"))
      try await store.unbindSession(from: card.id)
      return .ok("已解除「\(card.heading)」的会话关联。（\(card.id.shortID)）")
    case .say: return try await say(args)
    case .peek:
      switch try await references.place(args) {
      case .session(let session)?: return try await peek(session)
      case .task(let card)?: return try await peek(card)
      case nil: return try await board()
      }
    case .stop:
      let target = try await speaker(args)
      _ = try await store.stopSession(target.session, host: try await host(), cue: true)
      return .ok("已请\(target.label)停下这一轮。（\(target.short)）")
    case .leave:
      _ = try await host()  // 停用后不再替他判断谁接手
      let target = try await speaker(args)
      // 他在等你里答 Cue 问的那张卡，会话等的是 Cue 转达：再留给他回，同一件事就既在等你、又是待回复
      if let question = try await store.question(waitingOn: target.session) {
        let asked = question.asking?.question ?? CueEnvelope.clip(CueFormat.plainText(question.text), 40)
        throw Failure("等你里问着他「\(asked)」（\(question.id.shortID)），他在卡上答了你再转给会话：不用留给他回")
      }
      try await store.leaveToYou(target.session)
      return .ok("已把\(target.label)留给他回：进了等你、推到他手机，他或你再对它说话就作废。（\(target.short)）")
    case .take:
      _ = try await host()
      let target = try await speaker(args)
      guard try await store.takeBack(target.session) else { throw Failure("\(target.label)没留给他回（或已作废），不用收回") }
      return .ok("已收回\(target.label)：不再待回复、出了等你。（\(target.short)）")
    case .done: return try await done(args)
    }
  }

  /// 做完：Cue 按证据确认过就完成（`finishTask`）；顶层任务同时把结果告诉用户，所以要 evidence，结果上只挂 show 点名的图。已完成的只结束没人再用的会话。
  /// 给 session 是收掉那个会话（`CueStore.endIdleSession`）。
  private func done(_ args: Args) async throws -> Result {
    _ = try await host()  // 停用后不能再做完事
    if args.string("task") == nil, let ref = args.string("session") {
      // 给 session 是收掉会话，给 task 是做完任务：模型把任务编号填进 session 来 done 时，记录里原意都是做完那件任务（多是一个子任务），
      // 照收掉会话办就做错了事，所以这里不像 say、peek 那样认任务的编号
      guard case .session(let session) = try await references.sessionRef(ref) else {
        throw Failure("「\(ref)」是任务的编号：做完任务给 task；收掉会话给 session 写会话的 id（peek 里有）")
      }
      let ended = try await store.endIdleSession(session.sessionID) != nil
      return .ok((ended ? "已请会话「\(session.title)」结束" : "会话「\(session.title)」早已结束") + "。（\(session.shortID)）")
    }
    let card = try await references.task(args.required("task"))
    let reports = card.parentID == nil && card.status != .done
    let evidence = reports ? try Self.evidence(args) : []
    let shots = try CueShot.checked(try await shots(args.raw["show"]))
    if !reports, !shots.isEmpty { throw Failure("show 只跟着做完顶层任务：子任务与已完成的不写结果，没写") }
    let (report, ends) = try await store.finishTask(card.id, evidence: evidence, shots: shots, answeredRequests: nil)
    let ended = ends.isEmpty ? "" : "，已请 \(ends.count) 个会话结束"
    if card.status == .done {
      return .ok("「\(card.heading)」（\(card.id.shortID)）早已完成" + (ends.isEmpty ? "，没有要结束的会话（还在用的、已结束的不动）。" : "\(ended)。"))
    }
    return .ok(
      "「\(card.heading)」（\(card.id.shortID)）完成了" + ended
        + (report.map { "；结果已告诉用户（\($0.id.shortID)）" + (shots.isEmpty ? "，没挂图。" : "，挂着你点名的 \(shots.count) 张。") } ?? "。")
        + (reports ? try await waiting(beside: card) : "")
        + (report.map { "\n" + CueToolReceipt(.reply, $0.id).mark } ?? ""))
  }

  /// 做完一件顶层任务时，同一个项目里还没开工的几件（至多 `waitingLimit`）：等这件做完再做的事常已建好、没开工（他交代"做完这件再派"），
  /// 信封的"在做"里没有它们，做完那一刻看不到就另建一件同样的（长程评测 17 遍里 9 遍另建，4 遍靠同名才没建成两件）。没有为空。
  private func waiting(beside card: Card) async throws -> String {
    let todo = try await store.cueBoard().tasks.filter { $0.task.projectID == card.projectID && $0.task.status == .todo && !$0.isActive }
    guard !todo.isEmpty else { return "" }
    let named = todo.prefix(Self.waitingLimit).map { "「\($0.task.heading)」（\($0.task.id.shortID)）" }.joined(separator: "、")
    return "\n同项目里还没开工的：\(named)\(todo.count > Self.waitingLimit ? " 等 \(todo.count) 件" : "")；要接着做的是其中一件就 start 它，不另建。"
  }

  static let waitingLimit = 5

  /// 证据（done 做完顶层任务时）：1–`evidenceCount` 条，每条宽不过 `evidenceLimit`；不合就整件退回，什么都不写。
  private static func evidence(_ args: Args) throws -> [String] {
    let items = (args.strings("evidence") ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    guard (1...evidenceCount).contains(items.count) else { throw Failure("evidence 写 1–\(evidenceCount) 条证据（字符串数组），每条一句结论") }
    if let long = items.first(where: { CueName.width($0) > evidenceLimit }) {
      throw Failure("证据「\(long)」宽 \(CueName.width(long))，每条上限 \(evidenceLimit)（约 20 个汉字），没写：只写结论，如\"\(evidenceExample)\"，过程不写")
    }
    return items
  }

  /// Cue 写的名字（标题、子任务名）：去掉首尾空白后不空、宽不过 `CueName.limit`。不合抛错，调用方在写任何东西之前查完。
  private static func name(_ raw: String, _ what: String) throws -> String {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw Failure("\(what)不能为空") }
    let width = CueName.width(name)
    guard width <= CueName.limit else {
      throw Failure("\(what)「\(name)」宽 \(width)，上限 \(CueName.limit)（约 12 个汉字），什么都没写：只留要做成的结果，细节写进 body")
    }
    return name
  }

  /// start:true 是建好就开工（同 start，开工参数也同），一次调用办完；开工的参数与 Cue 是否在值班都在写之前查完。
  private func add(_ args: Args) async throws -> Result {
    let heading = try Self.name(try args.required("title"), "标题")
    let names = try (args.strings("steps") ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { try Self.name($0, "子任务") }
    let session = try await args.string("session").asyncMap(references.session)
    if session != nil, args.string("body") != nil { throw Failure("带 session 时不写 body：会话已经在做，话用 say 对它说") }
    let launch = args.bool("start") == true ? try await Launch(args, tools: self) : nil
    if session != nil, launch != nil { throw Failure("带 session 时不写 start：会话已经在做，话用 say 对它说") }
    if let session, let busy = try await store.tasks(boundTo: session.sessionID).first(where: { $0.task.piSessionID == session.sessionID && $0.task.status != .done }) {
      throw Failure("会话「\(session.title)」正在做「\(busy.task.heading)」（\(busy.task.id.shortID)）：同一件事接着做用 say 或给它 edit 加子任务")
    }
    let projectID = try await references.addProject(args, session: session)
    // 同一件事建第二份（重试、同一轮里并发发出的两次 add）只会开出第二个会话：返回已有的那件
    if session == nil, let same = try await references.openTopTask(titled: heading, in: projectID) {
      let dropped = args.string("body") != nil || !names.isEmpty ? "，这次的正文与子任务也没写（要改用 edit）" : ""
      let unstarted = launch == nil ? "" : "，也没开工（它没开工就 start）"
      return .ok("已有没做完的「\(same.heading)」（\(same.id.shortID)），没再建\(dropped)\(unstarted)：同一件事接着用它。")
    }
    let top = try await store.createTask(CueLines.joined(title: heading, rest: args.string("body")), in: projectID)
    var steps: [UUID] = []
    for step in names { steps.append(try await store.createTask(step, under: top.id).id) }
    var text = "建好了「\(top.heading)」（\(top.id.shortID)）" + (steps.isEmpty ? "" : "，\(steps.count) 个子任务")
    if let session {
      let leaf = try await store.workingLeaf(of: top.id)
      try await store.bindSession(session.sessionID, to: leaf.id)
      text += "，" + (leaf.id == top.id ? "" : "「\(leaf.heading)」") + "绑上了会话「\(session.title)」"
    }
    text += "，在项目「\(try await store.project(projectID)?.name ?? "")」里。"
    guard let launch else { return .ok(text) }
    do {
      let started = try await self.start(try await store.workingLeaf(of: top.id), launch)
      return Result(text: text + started.text, isError: started.isError)
    } catch {
      return Result(text: text + "没开工：\(Self.message(error))（建好的任务照留，修好后 start）", isError: true)
    }
  }

  private func edit(_ args: Args) async throws -> Result {
    let card = try await references.task(args.required("task"))
    // 先查完再写，免得标题、子任务改了一半才报错
    let heading = try args.string("title").map { try Self.name($0, "标题") }
    let steps = try args.strings("steps").map { try $0.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { try Self.name($0, "子任务") } }
    if steps != nil, card.parentID != nil { throw Failure("子任务只能加在顶层任务上：task 写它的顶层任务") }
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
      let cleared = body.trimmingCharacters(in: .whitespacesAndNewlines) == Self.cleared
      try await store.updateCard(card.id) { $0.rest = cleared ? nil : body }
      done.append(cleared ? "清掉了正文" : "换了正文")
    }
    if let steps {
      let existing = Set(try await store.children(of: card.id).filter(\.isTask).map { $0.heading })
      var added = 0
      for step in steps where !existing.contains(step) {
        _ = try await store.createTask(step, under: card.id)
        added += 1
      }
      done.append("追加了 \(added) 个子任务")
    }
    if let ref = args.string("project") {
      let project = try await references.project(ref)
      let top = try await store.topTask(of: card.id)
      try await store.moveCard(top, to: .top(project: project.id), after: nil)
      done.append("连同子任务挪到了项目「\(project.name)」")
    }
    guard !done.isEmpty else { throw Failure("edit 至少给 title、body、steps、project、reopen 之一") }
    return .ok("「\(card.heading)」（\(card.id.shortID)）：\(done.joined(separator: "，"))。")
  }

  /// 开工的参数（start 与 add 带 start:true 共用），连同在哪台 Mac 开：都查完才开工。
  private struct Launch {
    var agent: AgentKind?
    var model: String?
    var thinking: ThinkingLevel?
    var fresh: Bool
    var host: String

    init(_ args: Args, tools: CueTools) async throws {
      agent = try args.string("agent").map { raw -> AgentKind in
        guard let agent = AgentKind(rawValue: raw) else { throw Failure("agent 只能是 \(CueTools.agents)") }
        return agent
      }
      model = args.string("model")
      thinking = try CueTools.effort(args)
      fresh = args.bool("fresh") == true
      host = try await tools.host()
    }
  }

  private func start(_ args: Args) async throws -> Result {
    let leaf = try await references.workingLeaf(try args.required("task"))
    return try await start(leaf, try await Launch(args, tools: self))
  }

  private func start(_ leaf: Card, _ launch: Launch) async throws -> Result {
    let host = launch.host
    let request = try await store.startLeaf(
      leaf.id, agent: launch.agent, fresh: launch.fresh, model: launch.model, thinking: launch.thinking, host: host, cue: true)
    if request.mode == .known(.start) { return .ok("已请 Mac 为「\(leaf.heading)」开新会话，正文作为第一句。（\(leaf.id.shortID)）\n\(CueToolReceipt(.request, request.id).mark)") }
    return try await spoken(request, "已请求「\(leaf.heading)」沿用上一步的会话，正文作为下一句", tail: leaf.id.shortID, from: host)
  }

  static func effort(_ args: Args) throws -> ThinkingLevel? {
    try args.string("effort").map { raw -> ThinkingLevel in
      guard let level = ThinkingLevel(rawValue: raw) else { throw Failure("effort 只能是 \(ThinkingLevel.allCases.map(\.rawValue).joined(separator: " / "))") }
      return level
    }
  }
}
