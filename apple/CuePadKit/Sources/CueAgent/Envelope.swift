import CueStore
import CueText
import Foundation

/// 交给 Cue 的大脑的一轮输入里的 `<cue>` 块（用户的话若有，由值班的管理器接在块后面）。
/// 块里第一行是时间，然后是项目、变化、在做的事（在做的任务与不归没做完的事的活会话，`CueBoard`）、等你、醒来的原因。
/// 新会话的第一条输入里，它前面还有记忆视图与对话视图（`CueKeeper`）。信封与系统提示里"你"是 Cue、"他"是用户。
public enum CueEnvelope {
  public struct Input: Sendable {
    public var now: Date
    /// 所有项目（`CueStore.projects`）：Cue 据此把活放进项目。
    public var projects: [Project]
    public var changes: [CueChange]
    /// 看板（`CueStore.cueBoard`）：只写在做的。
    public var board: CueBoard
    public var waiting: [CueMessage]
    /// 它留给他回的会话（`CueState.left`）：看板上这几个写"待回复"。
    public var left: [CueLeft]
    public var wake: CueWake
    /// 定时到点（`CueWake.schedule`）时到点的那几条
    public var fired: [Fired]
    /// 全部定时（`CueStore.cueSchedules`）：看板上挂着定时的任务写明
    public var schedules: [CueMemoryLine]
    /// 这一轮要写的语言不是中文时它的名字（他这句话的语言，他没开口时是界面语言，App 定）：系统提示是中文，只在系统提示里说一次，
    /// 照着中文句式回的还是中文（实测），所以每一轮在块尾再说一次；中文时为 nil，不写这一行。
    public var language: String?

    public init(
      now: Date, projects: [Project], changes: [CueChange],
      board: CueBoard, waiting: [CueMessage], left: [CueLeft] = [], wake: CueWake, fired: [Fired] = [], schedules: [CueMemoryLine] = [], language: String? = nil
    ) {
      self.language = language
      self.schedules = schedules
      self.fired = fired
      self.left = left
      self.now = now
      self.projects = projects
      self.changes = changes
      self.board = board
      self.waiting = waiting
      self.wake = wake
    }
  }

  public static func render(_ input: Input) -> String {
    var lines = ["<cue>", input.now.formatted(stamp)]

    lines.append("项目：" + input.projects.map(\.name).joined(separator: "、"))

    lines.append("变化（上次醒来之后）：" + (input.changes.isEmpty ? "无" : ""))
    lines += input.changes.map { "- \(change($0))" }

    let active = input.board.active
    lines.append("在做 \(active.count) 件" + (active.isEmpty ? "" : "："))
    lines += active.map { work in
      switch work {
      case .task(let item): "- \(boardLine(item, now: input.now, left: input.left, schedules: input.schedules))"
      case .session(let session): "- \(sessionLine(session, now: input.now, left: input.left))"
      }
    }

    lines.append("等你 \(input.waiting.count) 件" + (input.waiting.isEmpty ? "" : "："))
    lines += input.waiting.map { "- " + question($0) }

    lines.append("醒来：" + wake(input.wake))
    if case .schedule = input.wake { lines += input.fired.map { "- " + fired($0, now: input.now) } }
    if let language = input.language { lines.append("这一轮你写下的字都用\(language)（回复、tell、动态、任务、对会话说的话）") }
    lines.append("</cue>")
    return lines.joined(separator: "\n")
  }

  /// 交给大脑的他的话与回答（`CueStore.cueMessagesToDeliver`），一条一段：他的话是原话，里面的文件在话后各接一行本机路径（`AttachmentFiles.agentLine`，
  /// 引用照留，Cue 转给会话时原样写进去）；模型看不了图（`imagesAsFiles`）时图片也这样接一行，看得了的图另附；收起了卡（`setAside` 里 `setAsideBy` 是它的）就在后面列出，
  /// Cue 判断是不是在答它们；回答是他选了哪一项，选的是"以后……不用问"时说明 CuePad 已把它记进一直记着的记忆（免得 Cue 再记一条）。
  public static func delivered(_ pending: [CueMessage], setAside: [CueMessage], files: AttachmentFiles, imagesAsFiles: Bool) -> String {
    pending.map { message in
      guard message.author == .known(.you) else {
        let question = CueFormat.plainText(message.text).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let noted = message.allowsFromNowOn(message.answer) ? "（已照原话记进一直记着的记忆，不用再记）" : ""
        return "他回答了「\(question)」：\(message.answer ?? "")\(noted)"
      }
      let paths = CueFormat.parse(message.text).compactMap { token in
        AttachmentFiles.agentFile(token, imagesAsFiles: imagesAsFiles).flatMap { files.agentLine(key: $0.key, name: $0.name) }
      }
      let said = ([message.text] + paths).joined(separator: "\n")
      let cards = setAside.filter { $0.setAsideBy == message.id }
      guard !cards.isEmpty else { return said }
      return ([said, "", "（他开口收起了等你里的 \(cards.count) 张；他这句与它无关就 tell restore 放回：）"] + cards.map { "- " + question($0) }).joined(separator: "\n")
    }.joined(separator: "\n\n")
  }

  /// 定时到点的一条：哪条定时（带序号）、本该几点（`CueFire`）与挂着的任务。
  public struct Fired: Sendable {
    public var line: CueIndexedLine
    public var due: Date
    public var task: Card?

    public init(line: CueIndexedLine, due: Date, task: Card?) {
      self.line = line
      self.due = due
      self.task = task
    }
  }

  /// "#15 清理过期分支（每周一 9:00）· 任务「清理过期分支」（ab12cd34）· 本该 9:00，错过了，现在补上"。
  private static func fired(_ fired: Fired, now: Date) -> String {
    let line = fired.line.line
    var parts = ["#\(fired.line.index) \(line.text)（\(line.repeats.map(CueScheduleWords.repeats) ?? "一次")）"]
    if let task = fired.task { parts.append("任务「\(task.heading)」（\(task.id.shortID)）") }
    if CueFire.late(fired.due, at: now) { parts.append("本该 \(CueScheduleWords.time(fired.due, now: now))，错过了，现在补上") }
    return parts.joined(separator: " · ")
  }

  /// 一条提问一行：原话、id 与选项。
  private static func question(_ message: CueMessage) -> String {
    "\(clip(CueFormat.plainText(message.text), 80))（\(message.id.shortID)）选项：\((message.choices ?? []).joined(separator: " / "))"
  }

  private static func wake(_ wake: CueWake) -> String {
    switch wake {
    case .enabled: "刚启用"
    case .message: "他发来新消息"
    case .sessionActivity: "会话有动静"
    case .idle: "空闲，例行看一眼"
    case .schedule: "定时到点"
    }
  }

  private static func change(_ change: CueChange) -> String {
    let label: String =
      switch change.kind {
      case .settled: change.interrupted ? state(.known(.interrupted)) : "歇下"
      case .waitingForUser: "等回答"
      case .failed: "出错"
      case .undelivered: "发送失败"
      case .done: "完成"
      case .stalled: "等子代理 \(Int(PiSessionState.stallAfter / 60)) 分钟没动静"
      }
    var text = "[\(label)\(change.byUser ? " · 他说的" : "")] \(where_(change))"
    if let detail = change.detail, !detail.isEmpty { text += "：\(clip(detail, 120))" }
    if let reply = change.recap?.lastReply { text += " · 回复：\(clip(reply, 160))" }
    return text
  }

  /// 看板上的一件事（信封与 peek 共用）：在做的只有一个叶子时一行；同时在做几步时，头一行之后每步一行（缩进，带子任务的短 id）。
  /// 挂着定时的写明几点：重复的每次到点开工一次，做完一次不算这件事做完。
  static func boardLine(_ item: CueBoardItem, now: Date, left: [CueLeft] = [], schedules: [CueMemoryLine] = []) -> String {
    var parts = ["\(item.task.heading)（\(item.task.id.shortID)）"]
    if let line = schedules.first(where: { $0.task == item.task.id }) {
      if let repeats = line.repeats {
        parts.append("定时 \(CueScheduleWords.repeats(repeats))（做完这一次不 done）")
      } else if let at = line.remindAt {
        parts.append("定时 \(CueScheduleWords.time(at, now: now))")
      }
    }
    if let progress = item.progress { parts.append("子任务 \(progress.done)/\(progress.total)") }
    guard item.leaves.count > 1 else {
      let leaf = item.leaves[0]
      return (parts + leafParts(leaf, named: leaf.leaf.id == item.task.id ? nil : leaf.leaf.heading, now: now, left: left)).joined(separator: " · ")
    }
    parts.append("同时在做 \(item.leaves.count) 步：")
    return ([parts.joined(separator: " · ")] + item.leaves.map { leaf in
      "  - " + leafParts(leaf, named: "\(leaf.leaf.heading)（\(leaf.leaf.id.shortID)）", now: now, left: left).joined(separator: " · ")
    }).joined(separator: "\n")
  }

  /// 看板上一个不归没做完的事的活会话（信封与 peek 共用）：名字与短 id、状态与多久、近况。
  static func sessionLine(_ session: PiSessionState, now: Date, left: [CueLeft] = []) -> String {
    var parts = [sessionName(session), "\(state(session.state)) \(duration(now.timeIntervalSince(session.stateSince)))"]
    if left.contains(where: { $0.holds(for: session) }) { parts.append(leftNote) }
    if let recent = recent(session) { parts.append("近况：\(clip(recent, 80))") }
    return parts.joined(separator: " · ")
  }

  static let leftNote = "待回复"

  /// 会话在 Cue 眼里的称呼：会话名与短 id（Cue 的工具给 session 时写它）。
  static func sessionName(_ session: PiSessionState) -> String { "会话「\(session.title)」（\(session.shortID)）" }

  private static func leafParts(_ leaf: CueBoardLeaf, named name: String?, now: Date, left: [CueLeft]) -> [String] {
    let state = leaf.session.map { state($0.state) } ?? (leaf.launching ? "正在开会话" : leaf.sending ? "发送中" : "没开工")
    var parts = ["\(name.map { "\($0) › " } ?? "")\(state) \(duration(now.timeIntervalSince(leaf.since)))"]
    if let session = leaf.session, left.contains(where: { $0.holds(for: session) }) { parts.append(leftNote) }
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
    case .thinking, .tool, .compacting: "工作中"
    case .delegating: "等子代理交回"
    case .waitingForUser: "等回答"
    case .settled: "歇着"
    case .error: "出错"
    case .ended: "已结束"
    case .interrupted: "做到一半被打断"
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
    return flat.clipped(limit)
  }

  static func duration(_ seconds: TimeInterval) -> String {
    let minutes = max(0, Int(seconds / 60))
    if minutes < 1 { return "不到 1 分钟" }
    if minutes < 60 { return "\(minutes) 分钟" }
    if minutes < 48 * 60 { return "\(minutes / 60) 小时" + (minutes % 60 == 0 ? "" : " \(minutes % 60) 分") }
    return "\(minutes / 1440) 天"
  }

  /// 按此刻的时区现取（Mac 换了时区，下一次就跟着换）。2026-10-21 周三 09:05
  private static var stamp: Date.VerbatimFormatStyle {
    .init(
      format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) 周\(weekday: .narrow) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
      locale: Locale(identifier: "zh_CN"), timeZone: .current, calendar: Calendar(identifier: .gregorian))
  }
  static var clock: Date.VerbatimFormatStyle {
    .init(
      format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
      timeZone: .current, calendar: Calendar(identifier: .gregorian))
  }
}
