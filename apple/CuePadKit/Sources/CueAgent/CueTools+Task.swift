import CueStore
import CueText
import Foundation

extension CueTools {
  func task(_ args: Args) async throws -> Result {
    switch try args.required("action") {
    case "add": return try await add(args)
    case "edit": return try await edit(args)
    case "start": return try await start(args)
    case "say": return try await say(args)
    case "peek":
      if let ref = args.string("task") { return try await peek(try await task(ref)) }
      if let ref = args.string("session") {
        switch try await sessionRef(ref) {
        case .session(let session): return try await peek(session)
        case .task(let card): return try await peek(card)
        }
      }
      return try await board()
    case "stop":
      let target = try await speaker(args)
      _ = try await store.stopSession(target.session, host: try await host(), cue: true)
      return .ok("已请\(target.label)停下这一轮。（\(target.short)）")
    case "leave":
      _ = try await host()  // 停用后不再替他判断谁接手
      let target = try await speaker(args)
      // 他在等你里答 Cue 问的那张卡，会话等的是 Cue 转达：再留给他回，同一件事就既在等你、又是待回复
      if let question = try await store.question(waitingOn: target.session) {
        let asked = question.asking?.question ?? CueEnvelope.clip(CueFormat.plainText(question.text), 40)
        throw Failure("等你里问着他「\(asked)」（\(question.id.shortID)），他在卡上答了你再转给会话：不用留给他回")
      }
      try await store.leaveToYou(target.session)
      return .ok("已把\(target.label)留给他回：进了等你、推到他手机，他或你再对它说话就作废。（\(target.short)）")
    case "take":
      _ = try await host()
      let target = try await speaker(args)
      guard try await store.takeBack(target.session) != nil else { throw Failure("\(target.label)没留给他回（或已作废），不用收回") }
      return .ok("已收回\(target.label)：不再待回复、出了等你。（\(target.short)）")
    case "done": return try await done(args)
    case let other: throw Failure("task 没有 \(other)：可用 add / edit / start / say / peek / stop / leave / take / done")
    }
  }

  /// 做完：Cue 按证据确认过就完成（`finishTask`）；顶层任务同时把结果告诉用户，所以要 evidence，结果上只挂 show 点名的图。已完成的只结束没人再用的会话。
  /// 给 session 是收掉那个会话（`CueStore.endIdleSession`）。
  private func done(_ args: Args) async throws -> Result {
    _ = try await host()  // 停用后不能再做完事
    if args.string("task") == nil, let ref = args.string("session") {
      // 给 session 是收掉会话，给 task 是做完任务：模型把任务编号填进 session 来 done 时，记录里原意都是做完那件任务（多是一个子任务），
      // 照收掉会话办就做错了事，所以这里不像 say、peek 那样认任务的编号
      guard case .session(let session) = try await sessionRef(ref) else {
        throw Failure("「\(ref)」是任务的编号：做完任务给 task；收掉会话给 session 写会话的 id（peek 里有）")
      }
      let ended = try await store.endIdleSession(session.sessionID) != nil
      return .ok((ended ? "已请会话「\(session.title)」结束" : "会话「\(session.title)」早已结束") + "。（\(session.shortID)）")
    }
    let card = try await task(args.required("task"))
    let reports = card.parentID == nil && card.status != .done
    let evidence = reports ? try Self.evidence(args) : []
    let shots = try CueShot.checked(try await shots(args.raw["show"]))
    if !reports, !shots.isEmpty { throw Failure("show 只跟着做完顶层任务：子任务与已完成的不写结果，没写") }
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

  private func add(_ args: Args) async throws -> Result {
    let heading = try Self.name(try args.required("title"), "标题")
    let names = try (args.strings("steps") ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { try Self.name($0, "子任务") }
    let session = try await args.string("session").asyncMap(session)
    if session != nil, args.string("body") != nil { throw Failure("带 session 时不写 body：会话已经在做，话用 say 对它说") }
    if let session, let busy = try await store.tasks(boundTo: session.sessionID).first(where: { $0.task.piSessionID == session.sessionID && $0.task.status != .done }) {
      throw Failure("会话「\(session.title)」正在做「\(busy.task.heading)」（\(busy.task.id.shortID)）：同一件事接着做用 say 或给它 edit 加子任务")
    }
    // 没给 project：带会话的是会话所在的项目，其余进默认项目
    var project = try await args.string("project").asyncMap(project)
    if project == nil, let home = session?.projectID { project = try await store.projects().first { $0.id == home } }
    let projectID = project?.id ?? Project.defaultID
    // 同一件事建第二份（重试、同一轮里并发发出的两次 add）只会开出第二个会话：返回已有的那件
    if session == nil, let same = try await openTopTasks(titled: heading).first(where: { $0.projectID == projectID }) {
      let dropped = args.string("body") != nil || !names.isEmpty ? "，这次的正文与子任务也没写（要改用 edit）" : ""
      return .ok("已有没做完的「\(same.heading)」（\(same.id.shortID)），没再建\(dropped)：同一件事接着用它。")
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
    return .ok(text)
  }

  private func edit(_ args: Args) async throws -> Result {
    let card = try await task(args.required("task"))
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
      done.append("追加了 \(added) 个子任务")
    }
    if let ref = args.string("project") {
      let project = try await project(ref)
      let top = try await store.topTask(of: card.id)
      try await store.moveCard(top, to: .top(project: project.id), after: nil)
      done.append("连同子任务挪到了项目「\(project.name)」")
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
    let host = try await host()
    let request = try await store.startLeaf(
      leaf.id, agent: agent, fresh: args.bool("fresh") == true, model: args.string("model"), thinking: try Self.effort(args), host: host, cue: true)
    if request.mode == .known(.start) { return .ok("已请 Mac 为「\(leaf.heading)」开新会话，正文作为第一句。（\(leaf.id.shortID)）") }
    return try await spoken(request, "「\(leaf.heading)」接着用上一步的会话，正文作为下一句（送到后这一步绑上它）", tail: leaf.id.shortID, from: host)
  }

  static func effort(_ args: Args) throws -> PiThinkingLevel? {
    try args.string("effort").map { raw -> PiThinkingLevel in
      guard let level = PiThinkingLevel(rawValue: raw) else { throw Failure("effort 只能是 \(PiThinkingLevel.allCases.map(\.rawValue).joined(separator: " / "))") }
      return level
    }
  }
}
