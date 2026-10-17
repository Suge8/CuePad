import CueStore
import CueText
import Foundation

/// Cue 这次为什么醒来。
public enum CueWake: Equatable, Sendable {
  /// 刚启用：第一次醒来
  case enabled
  /// 你发来新消息
  case message
  /// 在做的事里的会话有动静
  case sessionActivity
  /// 空闲时的例行查看
  case idle
  /// 提醒到点（到点的那几条记忆）
  case reminder([CueIndexedLine])
  /// 写下交接、换了新上下文：接着做（交接在信封的"接上"里）
  case renewed
  /// 他改了名字或 Agent，要换大脑：先写交接
  case settingsChanged
}

/// 交给 Cue 的大脑的一轮输入：一个 `<cue>` 块，你的话（若有）接在块后面。
/// 块里第一行是"时间 · 上下文 已用 / 换新线"，然后是项目、变化、在做的事（在做的任务与不归没做完的事的活会话，`CueBoard`）、等你、
/// 接上的（新上下文第一次醒来才有）、醒来的原因。
public enum CueEnvelope {
  /// 接上的对话至多这么多条、这么多字（从最近的往前取，一条也放不下时截短最近那条）。只为接上最近几轮来回（一轮一到三条），
  /// 合起来约是换新线（`CueContext.renewAt`，6 万 token）的十分之一，新上下文一开始不至于离换新线太近；更早的事在记忆与交接里。
  public static let resumeMessages = 30
  public static let resumeCharacters = 6000

  public struct Input: Sendable {
    public var now: Date
    /// 上下文已用多少 token；不知道为 nil。
    public var contextUsed: Int?
    /// 用到这么多 token 就该换新上下文。
    public var renewAt: Int
    /// 所有项目（`CueStore.cueProjects`）：Cue 据此把活放进项目。
    public var projects: [CueProject]
    public var changes: [CueChange]
    /// 看板（`CueStore.cueBoard`）：只写在做的。
    public var board: CueBoard
    public var waiting: [CueMessage]
    public var wake: CueWake
    /// 新上下文第一次醒来：接上的交接与对话（不含这次交出去的话）；其余为 nil
    public var resume: CueResume?
    /// 你这次说的话（`CueFormat` 正文）；没有为 nil。
    public var said: String?

    public init(
      now: Date, contextUsed: Int?, renewAt: Int, projects: [CueProject], changes: [CueChange],
      board: CueBoard, waiting: [CueMessage], wake: CueWake, resume: CueResume? = nil, said: String?
    ) {
      self.resume = resume
      self.now = now
      self.contextUsed = contextUsed
      self.renewAt = renewAt
      self.projects = projects
      self.changes = changes
      self.board = board
      self.waiting = waiting
      self.wake = wake
      self.said = said
    }
  }

  public static func render(_ input: Input) -> String {
    let calendar = Calendar(identifier: .gregorian)
    let used = input.contextUsed.map(CueContext.tokens) ?? "未知"
    var lines = ["<cue>", "\(stamp(input.now, calendar)) · 上下文 \(used) / 换新线 \(CueContext.tokens(input.renewAt))"]

    lines.append("项目：" + (input.projects.isEmpty ? "无" : input.projects.map { $0.name + ($0.hasFolder ? "" : "（没绑文件夹）") }.joined(separator: "、")))

    lines.append("变化（上次醒来之后）：" + (input.changes.isEmpty ? "无" : ""))
    lines += input.changes.map { "- \(change($0))" }

    let active = input.board.tasks.filter(\.isActive), sessions = input.board.sessions
    lines.append("在做 \(active.count + sessions.count) 件" + (active.isEmpty && sessions.isEmpty ? "" : "："))
    lines += active.map { "- \(boardLine($0, now: input.now))" }
    lines += sessions.map { "- \(sessionLine($0, now: input.now))" }

    lines.append("等你 \(input.waiting.count) 件" + (input.waiting.isEmpty ? "" : "："))
    lines += input.waiting.map { message in
      "- \(clip(CueFormat.plainText(message.text), 80))（\(message.id.shortID)）选项：\((message.choices ?? []).joined(separator: " / "))"
    }

    if let resume = input.resume { lines += self.resume(resume, calendar) }
    lines.append("醒来：" + wake(input.wake))
    if case .reminder(let due) = input.wake { lines += due.map { "- #\($0.index) \($0.line.text)" } }
    lines.append("</cue>")
    if let said = input.said, !said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.append(said) }
    return lines.joined(separator: "\n")
  }

  private static func wake(_ wake: CueWake) -> String {
    switch wake {
    case .enabled: "刚启用"
    case .message: "你发来新消息"
    case .sessionActivity: "会话有动静"
    case .idle: "空闲，例行看一眼"
    case .reminder: "提醒到点"
    case .renewed: "换了新上下文，从接上的地方接着做"
    case .settingsChanged: "他改了你的名字或 Agent，要换新上下文：先 memory renew 写交接备忘，再结束这一轮"
    }
  }

  /// 接上：交接原样，之后的对话每条一行，从最近的往前取到 `resumeCharacters` 字。
  private static func resume(_ resume: CueResume, _ calendar: Calendar) -> [String] {
    guard resume.handoff != nil || !resume.messages.isEmpty else { return [] }
    var budget = resumeCharacters, kept: [String] = []
    for message in resume.messages.reversed() {
      let author = switch message.author.known {
      case .you: "他"
      case .cue: "你"
      default: "你的动态"
      }
      var text = CueFormat.plainText(message.text)
      if let answer = message.answer { text += "（他回答：\(answer)）" }
      let line = clip(text, kept.isEmpty ? budget : Int.max)
      guard line.count <= budget else { break }
      budget -= line.count
      kept.append("- \(author) \(clock(message.createdAt, calendar))：\(line)")
    }
    let truncated = resume.truncated || kept.count < resume.messages.count
    return ["接上（新上下文：上一段的交接备忘与它之后的对话）：", "交接备忘：" + (resume.handoff == nil ? "没有，从头算起" : ""),
      resume.handoff.map(\.text), "之后的对话" + (truncated ? "（更早的略去）" : "") + (kept.isEmpty ? "：无" : "：")
    ].compactMap { $0 } + kept.reversed()
  }

  private static func change(_ change: CueChange) -> String {
    let label: String =
      switch change.kind {
      case .settled: change.interrupted ? state(.known(.interrupted)) : "歇下"
      case .waitingForUser: "等回答"
      case .failed: "出错"
      case .undelivered: "发送失败"
      case .done: "完成"
      }
    var text = "[\(label)\(change.byUser ? " · 他说的" : "")] \(where_(change))"
    if let detail = change.detail, !detail.isEmpty { text += "：\(clip(detail, 120))" }
    if let reply = change.recap?.lastReply { text += " · 回复：\(clip(reply, 160))" }
    return text
  }

  /// 看板上的一件事（信封与 peek 共用）：在做的只有一个叶子时一行；同时在做几步时，头一行之后每步一行（缩进，带步骤的短 id）。
  static func boardLine(_ item: CueBoardItem, now: Date) -> String {
    var parts = ["\(item.task.heading)（\(item.task.id.shortID)）"]
    if let progress = item.progress { parts.append("步骤 \(progress.done)/\(progress.total)") }
    guard item.leaves.count > 1 else {
      let leaf = item.leaves[0]
      return (parts + leafParts(leaf, named: leaf.leaf.id == item.task.id ? nil : leaf.leaf.heading, now: now)).joined(separator: " · ")
    }
    parts.append("同时在做 \(item.leaves.count) 步：")
    return ([parts.joined(separator: " · ")] + item.leaves.map { leaf in
      "  - " + leafParts(leaf, named: "\(leaf.leaf.heading)（\(leaf.leaf.id.shortID)）", now: now).joined(separator: " · ")
    }).joined(separator: "\n")
  }

  /// 看板上一个不归没做完的事的活会话（信封与 peek 共用）：名字与短 id、状态与多久、近况。
  static func sessionLine(_ session: PiSessionState, now: Date) -> String {
    var parts = [sessionName(session), "\(state(session.state)) \(duration(now.timeIntervalSince(session.stateSince)))"]
    if let recent = recent(session) { parts.append("近况：\(clip(recent, 80))") }
    return parts.joined(separator: " · ")
  }

  /// 会话在 Cue 眼里的称呼：会话名与短 id（Cue 的工具给 session 时写它）。
  static func sessionName(_ session: PiSessionState) -> String { "会话「\(session.title)」（\(session.shortID)）" }

  private static func leafParts(_ leaf: CueBoardLeaf, named name: String?, now: Date) -> [String] {
    let state = leaf.session.map { state($0.state) } ?? (leaf.launching ? "正在开会话" : leaf.sending ? "发送中" : "没开工")
    var parts = ["\(name.map { "\($0) › " } ?? "")\(state) \(duration(now.timeIntervalSince(leaf.since)))"]
    if let session = leaf.session, let recent = recent(session) { parts.append("近况：\(clip(recent, 80))") }
    return parts
  }

  /// 近况只写此刻还开着的：在等的提问、正在做的动作、正在处理的话。做完的回复不写：歇下时已作为变化报过（带回复），
  /// 每次醒来再列一遍只是重复；要看就 peek 那件事。
  private static func recent(_ session: PiSessionState) -> String? {
    if session.state == .known(.waitingForUser), let question = session.question { return question.text }
    if session.state.isWorking, let detail = session.detail { return detail }
    return session.pendingPrompt.map { "在处理：\($0)" }
  }

  /// 会话状态在 Cue 眼里的说法（看板、变化与 peek 共用）。
  static func state(_ state: Open<PiWorkState>) -> String {
    switch state.known {
    case .thinking, .tool, .delegating, .compacting: "工作中"
    case .waitingForUser: "等回答"
    case .settled: "歇着"
    case .error: "出错"
    case .ended: "已结束"
    case .interrupted: "做到一半被打断"
    case .incompatible: "版本不兼容"
    case nil: state.rawValue
    }
  }

  private static func where_(_ change: CueChange) -> String {
    guard let task = change.task else { return change.session.map(sessionName) ?? "" }
    let base = "\(task.heading)（\(task.id.shortID)）"
    guard let leaf = change.leaf, leaf.id != task.id else { return base }
    return "\(base) › \(leaf.heading)"
  }

  static func clip(_ text: String, _ limit: Int) -> String {
    let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
  }

  static func duration(_ seconds: TimeInterval) -> String {
    let minutes = max(0, Int(seconds / 60))
    if minutes < 1 { return "不到 1 分钟" }
    if minutes < 60 { return "\(minutes) 分钟" }
    if minutes < 48 * 60 { return "\(minutes / 60) 小时" + (minutes % 60 == 0 ? "" : " \(minutes % 60) 分") }
    return "\(minutes / 1440) 天"
  }

  private static let weekdays = ["日", "一", "二", "三", "四", "五", "六"]

  private static func stamp(_ date: Date, _ calendar: Calendar) -> String {
    let c = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
    return "\(c.year!)-\(pad(c.month!))-\(pad(c.day!)) 周\(weekdays[c.weekday! - 1]) \(clock(date, calendar))"
  }

  private static func clock(_ date: Date, _ calendar: Calendar) -> String {
    let c = calendar.dateComponents([.hour, .minute], from: date)
    return "\(pad(c.hour!)):\(pad(c.minute!))"
  }

  private static func pad(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
}
