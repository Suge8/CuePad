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
  /// 换新上下文后的第一轮：上一段写下的交接备忘
  case renewed(handoff: String)
}

/// 交给 Cue 的大脑的一轮输入：一个 `<cue>` 块，你的话（若有）接在块后面。
/// 块里第一行是"时间 · 上下文 已用 / 换新线"，然后是项目、变化、在做的事（`CueBoardItem.isActive`）、等你、醒来的原因。
public enum CueEnvelope {
  public struct Input: Sendable {
    public var now: Date
    public var timeZone: TimeZone
    /// 上下文已用多少 token；不知道为 nil。
    public var contextUsed: Int?
    /// 用到这么多 token 就该换新上下文。
    public var renewAt: Int
    public var since: Date
    /// 所有项目（`CueStore.cueProjects`）：Cue 据此把活放进项目。
    public var projects: [CueProject]
    public var changes: [CueChange]
    /// 你关掉、还没告诉 Cue 的提问（`CueStore.cueMessagesToDeliver` 里没选就结束的）：写在变化里。
    public var dismissed: [CueMessage]
    /// 看板（`CueStore.cueBoard`）：只写在做的。
    public var board: [CueBoardItem]
    public var waiting: [CueMessage]
    public var wake: CueWake
    /// 你这次说的话（`CueFormat` 正文）；没有为 nil。
    public var said: String?

    public init(
      now: Date, timeZone: TimeZone = .current, contextUsed: Int?, renewAt: Int, since: Date, projects: [CueProject], changes: [CueChange],
      dismissed: [CueMessage], board: [CueBoardItem], waiting: [CueMessage], wake: CueWake, said: String?
    ) {
      self.now = now
      self.timeZone = timeZone
      self.contextUsed = contextUsed
      self.renewAt = renewAt
      self.since = since
      self.projects = projects
      self.changes = changes
      self.dismissed = dismissed
      self.board = board
      self.waiting = waiting
      self.wake = wake
      self.said = said
    }
  }

  public static func render(_ input: Input) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = input.timeZone
    let used = input.contextUsed.map(tokens) ?? "未知"
    var lines = ["<cue>", "\(stamp(input.now, calendar)) · 上下文 \(used) / 换新线 \(tokens(input.renewAt))"]

    lines.append("项目：" + (input.projects.isEmpty ? "无" : input.projects.map { $0.name + ($0.hasFolder ? "" : "（没绑文件夹）") }.joined(separator: "、")))

    let since = calendar.isDate(input.since, inSameDayAs: input.now) ? clock(input.since, calendar) : stamp(input.since, calendar)
    lines.append("变化（\(since) 之后）：" + (input.changes.isEmpty && input.dismissed.isEmpty ? "无" : ""))
    lines += input.changes.map { "- \(change($0))" }
    lines += input.dismissed.map { "- [关掉提问] 他没选就关掉了「\(clip(CueFormat.plainText($0.text), 80))」（\($0.id.shortID)）" }

    let active = input.board.filter(\.isActive)
    lines.append("在做 \(active.count) 件" + (active.isEmpty ? "" : "："))
    lines += active.map { "- \(boardLine($0, now: input.now))" }

    lines.append("等你 \(input.waiting.count) 件" + (input.waiting.isEmpty ? "" : "："))
    lines += input.waiting.map { message in
      "- \(clip(CueFormat.plainText(message.text), 80))（\(message.id.shortID)）选项：\((message.choices ?? []).joined(separator: " / "))"
    }

    lines.append("醒来：" + wake(input.wake))
    if case .reminder(let due) = input.wake { lines += due.map { "- #\($0.index) \($0.line.text)" } }
    if case .renewed(let handoff) = input.wake { lines.append(handoff) }
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
    case .renewed: "换了新上下文，上一段的交接："
    }
  }

  private static func change(_ change: CueChange) -> String {
    let label: String =
      switch change.kind {
      case .settled: change.interrupted ? state(.known(.interrupted)) : "歇下"
      case .waitingForUser: "等回答"
      case .failed: "出错"
      case .done: "完成"
      }
    var text = "[\(label)] \(where_(change))"
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

  private static func leafParts(_ leaf: CueBoardLeaf, named name: String?, now: Date) -> [String] {
    let state = leaf.session.map { state($0.state) } ?? (leaf.launching ? "正在开会话" : leaf.sending ? "发送中" : "没开工")
    var parts = ["\(name.map { "\($0) › " } ?? "")\(state) \(duration(now.timeIntervalSince(leaf.since)))"]
    if let session = leaf.session, let recent = recent(session) { parts.append("近况：\(clip(recent, 80))") }
    return parts
  }

  private static func recent(_ session: PiSessionState) -> String? {
    if session.state == .known(.waitingForUser), let question = session.question { return question.text }
    if session.state.isWorking, let detail = session.detail { return detail }
    return session.pendingPrompt.map { "在处理：\($0)" } ?? session.lastReply
  }

  /// 会话状态在 Cue 眼里的说法（看板、变化与 peek 共用）。
  static func state(_ state: Open<PiWorkState>) -> String {
    switch state.known {
    case .thinking, .outputting, .tool, .delegating, .compacting: "工作中"
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
    let base = "\(change.task.heading)（\(change.task.id.shortID)）"
    guard let leaf = change.leaf, leaf.id != change.task.id else { return base }
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

  /// token 数的写法（信封第一行与 Mac 的"运行情况"同一种）：不到一千写原数，往上写 5.3k、128k。
  public static func tokens(_ count: Int) -> String {
    count >= 1000 ? "\((Double(count) / 1000).formatted(.number.precision(.fractionLength(0...1))))k" : "\(count)"
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
