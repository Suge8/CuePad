import CueStore
import CueText
import Foundation

extension CueTools {
  /// 在做的归 Cue 管，其余是用户手上的清单。末尾最近完成的各带会话与它此刻的状态：他接着交代其中一件的下一步时在原任务上加一步（同系统提示"接着用"），
  /// 在旧会话上做别的事才 add 带 session（只写后一种时，做完的调研他接着说"先升第一档"，长程评测里另建了一件）。
  func board() async throws -> Result {
    let board = try await store.cueBoard()
    let left = try await store.cueState()?.left ?? []
    let schedules = try await store.cueScheduleLines()
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
      lines.append(("- " + CueEnvelope.boardLine(item, now: now, left: left, schedules: schedules), true))
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
      lines.append(("最近完成的（他接着交代其中一件的下一步：edit 加子任务再 start；在它的会话上做另一件事：add 带 session）：", false))
      lines += recent.map { ("- \($0.task.heading)（\($0.task.id.shortID)） · " + CueEnvelope.sessionLine($0.session, now: now), true) }
    }
    return .ok(
      (total == 0 ? "没有没做完的事。" : "没做完的 \(total) 件，在做 \(board.active.count) 件：")
        + (lines.isEmpty ? "" : "\n" + lines.map(\.text).joined(separator: "\n")))
  }

  /// 信封里变化说到的那几件事的近况（`CueEnvelope.Input.recaps`），就是 peek 给的那一份：Cue 醒来就能核对证据，不用再 peek 一次
  /// （每次工具调用都要把整段前缀再读一遍）。一件一份，按变化的先后放，放不下 `recapBudget` 的那件不带，变化那一行照旧写截短的回复。
  /// 完成的不带：做完是定了的事，不用再核对证据；叫醒那一刻会话的记录常还没写完，近况只有开工那句。带的 4 遍里 Cue 每遍照样再 peek，省不下调用（整件任务完成已不叫醒 Cue，这条多半只碰上子任务完成）。
  public func recaps(for changes: [CueChange]) async throws -> [CueEnvelope.Subject: String] {
    var recaps: [CueEnvelope.Subject: String] = [:], seen = Set<CueEnvelope.Subject>(), room = Self.recapBudget
    for change in changes where change.kind != .done {
      guard let subject = CueEnvelope.Subject(change), seen.insert(subject).inserted, let text = try await recap(change), text.count <= room else { continue }
      recaps[subject] = text
      room -= text.count
    }
    return recaps
  }

  private func recap(_ change: CueChange) async throws -> String? {
    if let task = change.task { return try await peek(task).text }
    return try await change.session.asyncMap { try await peek($0).text }
  }

  /// 一个信封里近况合起来最多这么多字。一份近况通常一两千字（真实库里会话回答的中位 366 字、P99 约 2500 字，peek 再带两三轮截短的问答与正文），
  /// 最长约 6000 字（最新回答截到 `latestReplyLimit`）；真实库里会话叫醒 Cue 时至多 4 件事有变化（96% 只有一件）。12000 字装得下两份最长的或五六份常见的，
  /// 合起来约 1 万 token，是换新线（`CueContext.renewAt`）的一成：一次很多变化也不会把一轮的上下文撑到要换新。
  static let recapBudget = 12_000

  static let recentlyDone = 5

  /// peek 里每个叶子最新的那条回答最多给这么多字：超了留开头 `latestReplyHead` 字与结尾，截掉中间。结论多在开头，证据、没做完的多在结尾
  /// （真实库里超长的回答不到 0.3%，多数的证据在第 4000 字之后），截尾会把它们截掉；中间多是过程。
  static let latestReplyLimit = 4000
  static let latestReplyHead = 1000

  static let overviewLimit = 60

  /// 会话是哪家 Agent 的（本版本不认识的写 Agent）。
  static func agentName(_ session: SessionState) -> String { session.agent.known?.name ?? "Agent" }

  func peek(_ card: Card) async throws -> Result {
    let detail = try await store.cueTaskDetail(card.id)
    let now = store.timing.now(), left = try await store.cueState()?.left ?? []
    // 在哪个项目里：他放行的范围写的是项目（"以后「演示」里推送代码不用问"），不写出来就对不上
    let project = try await store.projects().first { $0.id == detail.task.projectID }?.name
    var lines = [
      "「\(detail.task.heading)」（\(detail.task.id.shortID)）" + (project.map { " · 项目「\($0)」" } ?? "")
        + (detail.progress.map { " · 子任务 \($0.done)/\($0.total)" } ?? "") + " · " + status(detail.task)
    ]
    // 几步接着用同一个会话（start 的缺省）时，会话与它的问答只列在最后用它的那一步下面：每步各列一遍是同一段字重复几次
    let lastUse = Dictionary(detail.leaves.enumerated().compactMap { index, leaf in leaf.session.map { ($0.session.sessionID, index) } }) { _, later in later }
    for (index, leaf) in detail.leaves.enumerated() {
      var head = leaf.leaf.id == detail.task.id ? "-" : "- 「\(leaf.leaf.heading)」（\(leaf.leaf.id.shortID)）\(status(leaf.leaf))"
      if let session = leaf.session, lastUse[session.session.sessionID] != index {
        lines.append(head + " · 会话同后面的一步")
        if let rest = leaf.leaf.rest { lines.append("  正文：\(CueEnvelope.clip(CueFormat.plainText(rest), 200))") }
        continue
      }
      if let session = leaf.session {
        head += " · " + Self.sessionHead(session.session, now: now, left: left)
      } else if let request = leaf.handoffs.last, case .preparing(let reason) = Speech.trip(request, at: .always(at: now)) {
        head += " · \(reason)（原请求仍保留，不要重复开工）"
      } else {
        head += leaf.handoffs.isEmpty ? " · 没有会话" : " · 前次投送尚未确认（可能已经执行，先核对，不要重复开工）"
      }
      lines.append(head)
      if let session = leaf.session { lines += Self.subagentLines(session.session, now: now) }
      // 会话里有开工那一句（与标题加正文一字不差）就不另列正文：那一句是 Cue 说的，在问答或更早说过的里照原文列全
      let opened = leaf.session.map { Self.opening(in: $0, body: leaf.leaf.body) } ?? false
      if !opened, let rest = leaf.leaf.rest { lines.append("  正文：\(CueEnvelope.clip(CueFormat.plainText(rest), 200))") }
      if let session = leaf.session { lines += Self.conversation(session, opening: opened ? leaf.leaf.body : nil) }
    }
    lines += deliveredLines(try await store.deliverables(of: detail.task.id))
    return .ok(lines.joined(separator: "\n"))
  }

  func peek(_ session: SessionState) async throws -> Result {
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

  /// 发到手机的文件，每份一行：id（提问与做完的 show 照它点名）、标题、类型、发来的时刻与本机路径（读文件工具按扩展名认类型，本机那份的扩展名由附件的键定）。
  private func deliveredLines(_ previews: [PreviewItem]) -> [String] {
    guard !previews.isEmpty else { return [] }
    return ["发到手机的（id，图片、PDF 用 read 打开）："] + previews.map { preview in
      "  - \(preview.id.shortID) 「\(preview.title)」\(preview.kind?.label ?? preview.name) · \(Self.clock(preview.createdAt)) · "
        + (store.files.fileURL(for: preview.key)?.path ?? "还没同步到这台 Mac")
    }
  }

  private static func clock(_ date: Date) -> String {
    date.formatted(.verbatim("\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)", timeZone: .current, calendar: .current))
  }

  private static func sessionHead(_ session: SessionState, now: Date, left: [CueLeft]) -> String {
    var head = "\(agentName(session))会话「\(session.title)」\(CueEnvelope.state(session.state)) \(CueEnvelope.duration(now.timeIntervalSince(session.stateSince)))"
    if left.contains(where: { $0.holds(for: session) }) { head += " · " + CueEnvelope.leftNote }
    if let question = session.question {
      head += " · 提问：\(CueEnvelope.clip(question.text, 120))" + (question.options.isEmpty ? "" : "（\(question.options.joined(separator: " / "))）")
    }
    return head
  }

  /// 会话带的子代理此刻怎样，每个一行、缩进两格：名册是 Agent 报给 Mac 的（FireCode 的名册、Claude Code 的后台任务……），
  /// 主会话嘴上说在等的，照这里看是不是真在等。
  private static func subagentLines(_ session: SessionState, now: Date) -> [String] {
    guard !session.subagents.isEmpty else { return [] }
    let running = session.subagents.count(where: \.isRunning)
    return ["  子代理 \(session.subagents.count) 个，" + (running == 0 ? "都不在跑：" : "\(running) 个在跑：")]
      + session.subagents.map { agent in
        "  - \(agent.name)：\(subagentPhase(agent, now: now))" + (agent.action.isEmpty ? "" : "「\(CueEnvelope.clip(agent.action, 120))」")
      }
  }

  private static func subagentPhase(_ agent: SubagentState, now: Date) -> String {
    let settled = agent.settledAt.map { " \(clock($0))" } ?? ""
    return switch agent.phase.known {
    case .running: "在跑" + (agent.progressAt.map { now.timeIntervalSince($0) >= 60 ? "，\(CueEnvelope.duration(now.timeIntervalSince($0)))没动静" : "" } ?? "")
    case .review: "在被审查"
    case .paused: "临时故障，等到点自动续跑"
    case .done: "交回了" + settled
    case .failed: "失败了" + settled
    case .rejected: "审查没通过" + settled
    case .interrupted: "被停下" + settled
    case .idle: "歇着"
    case nil: agent.phase.rawValue
    }
  }

  /// 会话最近几轮问答（最新的回答给全文，常是测试输出与证据，太长截掉中间；他说的与更早的回答截短），每行缩进两格。
  /// `opening`：叶子的标题与正文（`opening(in:body:)` 认出了开工那一句）：那一句标明是开工的第一句。
  /// 前面先列更早你对它说过的（`earlier`，重发的同一句、最近几轮里你说过的只列一次；他或 Agent 说的同一句截短了，不算列过）：托付的事常在几轮之前，交回时不提它就会被漏掉
  /// （长程评测里"做完顺手升版本号"漏核对就 done，实测）。你说的每一句在这里只出现一次、原文照列不截：截掉的后半句里可能正是要核对的那件；
  /// 这是 Cue 自己写的短话（长程评测 234 句 say 中位 92 字、最长 347 字）。
  /// 这一轮还没答完时末尾再列它到目前最后说的一段（`Recap.pendingTools`）：会话停下来问之前说的（测试过没过、倾向哪个）常是拿主意的依据，
  /// 答完前它只在这一轮的经过里、不进对话（短场景"放行过的不再问"没它就看不到测试已过，答成不推送）。
  private static func conversation(_ detail: CueSessionDetail, opening: String? = nil) -> [String] {
    var lines: [String] = [], listed = Set(detail.recent.filter { $0.saidByCue(detail.cueSent) }.map { flat(CueFormat.plainText($0.text)) })
    let earlier = detail.earlier.map { CueFormat.plainText($0.text) }.filter { listed.insert(flat($0)).inserted }
    if !earlier.isEmpty {
      lines.append("  你更早对它说过的（交回时逐件核对做到没有，没做到的不算做完）：")
      lines += earlier.map { said in "  - " + (opening.map { same(said, $0) } == true ? "（开工的第一句，即标题与正文）" : "") + flat(said) }
    }
    let latest = detail.recent.lastIndex { $0.role == .known(.pi) }
    let agent = agentName(detail.session)
    for (index, message) in detail.recent.enumerated() {
      let text = CueFormat.plainText(message.text)
      guard index == latest else {
        let byCue = message.role != .known(.pi) && message.saidByCue(detail.cueSent)
        let who = message.role == .known(.pi) ? agent : byCue ? "你" : "他"
        let opens = byCue && opening.map { same(text, $0) } == true
        lines.append("  \(who)\(opens ? "（开工的第一句，即标题与正文）" : "")：\(byCue ? flat(text) : CueEnvelope.clip(text, 300))")
        continue
      }
      let cut = text.count - latestReplyLimit
      let full = cut > 0
        ? "\(text.prefix(latestReplyHead))\n（中间截掉 \(cut) 字；要找其中的话用 memory recall 查那里的词）\n\(text.suffix(latestReplyLimit - latestReplyHead))" : text
      lines.append("  \(agent)（最新的回答）：\n" + indented(full))
    }
    if let said = detail.session.pendingTools?.items.last(where: { $0.kind == .said })?.target {
      lines.append("  \(agent)（这一轮还没答完，到目前最后说的）：\n" + indented(CueFormat.plainText(said)))
    }
    return lines
  }

  private static func indented(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
  }

  /// 会话里你说过的一句（最近几轮或更早）与叶子的标题加正文一字不差（不计空白），就是开工那一句。
  private static func opening(in detail: CueSessionDetail, body: String) -> Bool {
    (detail.earlier + detail.recent).contains { $0.role != .known(.pi) && $0.saidByCue(detail.cueSent) && same(CueFormat.plainText($0.text), body) }
  }

  private static func same(_ said: String, _ body: String) -> Bool { flat(said) == flat(CueFormat.plainText(body)) }

  private static func flat(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

  private func status(_ card: Card) -> String {
    switch card.status {
    case .done: "完成"
    case .inProgress: "进行中"
    case .todo: "待办"
    case nil: ""
    }
  }
}
