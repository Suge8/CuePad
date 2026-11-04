import CueStore
import CueText
import Foundation

extension CueTools {
  /// 看板：所有没做完的顶层任务，按项目分组，再是不归没做完的事的活会话，至多 `overviewLimit` 行；在做的归 Cue 管，其余是用户手上的清单。
  /// 末尾是最近完成的 `recentlyDone` 件，各带会话与它此刻的状态：在旧会话上做别的事时从这里找（add 带 session）。
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
      lines.append(("最近完成的（会话还能接着用：在它上面做别的事用 add 带 session）：", false))
      lines += recent.map { ("- \($0.task.heading)（\($0.task.id.shortID)） · " + CueEnvelope.sessionLine($0.session, now: now), true) }
    }
    return .ok(
      (total == 0 ? "没有没做完的事。" : "没做完的 \(total) 件，在做 \(board.active.count) 件：")
        + (lines.isEmpty ? "" : "\n" + lines.map(\.text).joined(separator: "\n")))
  }

  /// 信封里变化说到的那几件事的近况（`CueEnvelope.Input.recaps`），就是 peek 给的那一份：Cue 醒来就能核对证据，不用再 peek 一次
  /// （每次工具调用都要把整段前缀再读一遍）。一件一份，按变化的先后放，放不下 `recapBudget` 的那件不带，变化那一行照旧写截短的回复。
  /// 两种不带（短场景 Pi + sonnet 实测，带与不带各跑几遍）：
  /// - 他发起的一轮停下（`CueChange.byUser`）：CuePad 已留给他回，Cue 多半只定收不收回，截短的回复够用。带上全文它会就着细节替他拿主意
  ///   （他那一轮碰上推送，转头问他推不推）：带的 4 遍错 3 遍，不带的 6 遍错 1 遍，改前 2 遍都对。
  /// - 完成：做完是定了的事，不用再核对证据；叫醒那一刻会话的记录常还没写完，近况只有开工那句。带的 4 遍里 Cue 每遍照样再 peek，省不下调用（整件任务完成已不叫醒 Cue，这条多半只碰上子任务完成）。
  public func recaps(for changes: [CueChange]) async throws -> [CueEnvelope.Subject: String] {
    var recaps: [CueEnvelope.Subject: String] = [:], seen = Set<CueEnvelope.Subject>(), room = Self.recapBudget
    for change in changes where !change.byUser && change.kind != .done {
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

  /// 不带参数的 peek 末尾列几件最近完成的。
  static let recentlyDone = 5

  /// peek 里每个叶子最新的那条回答最多给这么多字：超了留开头 `latestReplyHead` 字与结尾，截掉中间。结论多在开头，证据、没做完的多在结尾
  /// （真实库里超长的回答不到 0.3%，多数的证据在第 4000 字之后），截尾会把它们截掉；中间多是过程。
  static let latestReplyLimit = 4000
  static let latestReplyHead = 1000

  /// 不带 task 的 peek 的文字最多这么多行（含开头一行、项目名与"还有 N 件"）。
  static let overviewLimit = 60

  /// 会话是哪家 Agent 的（本版本不认识的写 Agent）。
  static func agentName(_ session: PiSessionState) -> String { session.agent.known?.name ?? "Agent" }

  func peek(_ card: Card) async throws -> Result {
    let detail = try await store.cueTaskDetail(card.id)
    let now = store.timing.now(), left = try await store.cueState()?.left ?? []
    var lines = [
      "「\(detail.task.heading)」（\(detail.task.id.shortID)）" + (detail.progress.map { " · 子任务 \($0.done)/\($0.total)" } ?? "")
        + " · " + status(detail.task)
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
      // 最近几轮里有开工那一句（与标题加正文一字不差）就不另列正文：那一句照原样列在问答里，截得比正文这行还宽
      let opened = leaf.session.map { Self.opening(in: $0, body: leaf.leaf.body) } ?? false
      if !opened, let rest = leaf.leaf.rest { lines.append("  正文：\(CueEnvelope.clip(CueFormat.plainText(rest), 200))") }
      if let session = leaf.session { lines += Self.conversation(session, opening: opened ? leaf.leaf.body : nil) }
    }
    lines += deliveredLines(try await store.deliverables(of: detail.task.id))
    return .ok(lines.joined(separator: "\n"))
  }

  func peek(_ session: PiSessionState) async throws -> Result {
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
  private func deliveredLines(_ previews: [PiPreview]) -> [String] {
    guard !previews.isEmpty else { return [] }
    return ["发到手机的（id，图片、PDF 用 read 打开）："] + previews.map { preview in
      "  - \(preview.id.shortID) 「\(preview.title)」\(preview.kind?.label ?? preview.name) · \(Self.clock(preview.createdAt)) · "
        + (store.files.fileURL(for: preview.key)?.path ?? "还没同步到这台 Mac")
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

  /// 会话最近几轮问答（最新的回答给全文，常是测试输出与证据，太长截掉中间；更早的截短），每行缩进两格。
  /// `opening`：叶子的标题与正文（`opening(in:body:)` 认出了开工那一句）：那一句标明是开工的第一句，原文照列。
  private static func conversation(_ detail: CueSessionDetail, opening: String? = nil) -> [String] {
    var lines: [String] = []
    let latest = detail.recent.lastIndex { $0.role == .known(.pi) }
    let agent = agentName(detail.session)
    for (index, message) in detail.recent.enumerated() {
      let text = CueFormat.plainText(message.text)
      guard index == latest else {
        let byCue = message.role != .known(.pi) && message.saidByCue(detail.cueSent)
        let who = message.role == .known(.pi) ? agent : byCue ? "你" : "他"
        let opens = byCue && opening.map { same(text, $0) } == true
        lines.append("  \(who)\(opens ? "（开工的第一句，即标题与正文）" : "")：\(CueEnvelope.clip(text, 300))")
        continue
      }
      let cut = text.count - latestReplyLimit
      let full = cut > 0
        ? "\(text.prefix(latestReplyHead))\n（中间截掉 \(cut) 字；要找其中的话用 memory recall 查那里的词）\n\(text.suffix(latestReplyLimit - latestReplyHead))" : text
      lines.append("  \(agent)（最新的回答）：\n" + full.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n"))
    }
    return lines
  }

  /// 最近几轮里你说过的一句与叶子的标题加正文一字不差（不计空白），就是开工那一句。
  private static func opening(in detail: CueSessionDetail, body: String) -> Bool {
    detail.recent.contains { $0.role != .known(.pi) && $0.saidByCue(detail.cueSent) && same(CueFormat.plainText($0.text), body) }
  }

  private static func same(_ said: String, _ body: String) -> Bool {
    let flat = { (text: String) in text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    return flat(said) == flat(CueFormat.plainText(body))
  }

  private func status(_ card: Card) -> String {
    switch card.status {
    case .done: "完成"
    case .inProgress: "进行中"
    case .todo: "待办"
    case nil: ""
    }
  }
}
