import CueStore
import CueText
import Foundation

public enum CueEnvelope {
  public struct Input: Sendable {
    public var now: Date
    public var projects: [Project]
    public var changes: [CueChange]
    public var recaps: [Subject: String]
    public var board: CueBoard
    public var waiting: [CueMessage]
    public var left: [CueLeft]
    public var wake: CueWake
    public var fired: [Fired]
    public var schedules: [CueMemoryLine]
    /// 这一轮要写的语言不是中文时它的名字（他这句话的语言，他没开口时是界面语言，App 定）：系统提示是中文，只在系统提示里说一次，
    /// 照着中文句式回的还是中文（实测），所以每一轮在块尾再说一次；中文时为 nil，不写这一行。
    public var language: String?
    public var quotas: [AccountQuota]
    public var retrying: String?
    public var related: [String]

    public init(
      now: Date, projects: [Project], changes: [CueChange], recaps: [Subject: String] = [:],
      board: CueBoard, waiting: [CueMessage], left: [CueLeft] = [], wake: CueWake, fired: [Fired] = [], schedules: [CueMemoryLine] = [], language: String? = nil,
      quotas: [AccountQuota] = [], retrying: String? = nil, related: [String] = []
    ) {
      self.related = related
      self.quotas = quotas
      self.retrying = retrying
      self.language = language
      self.schedules = schedules
      self.fired = fired
      self.left = left
      self.now = now
      self.projects = projects
      self.changes = changes
      self.recaps = recaps
      self.board = board
      self.waiting = waiting
      self.wake = wake
    }
  }

  public static func read(
    from store: CueStore, wake: CueWake, changes: [CueChange], now: Date, host: String, language: String?, retrying: String?, related: [String]
  ) async throws -> Input {
    Input(
      now: now, projects: try await store.projects(), changes: changes, recaps: try await CueTools(store: store).recaps(for: changes),
      board: try await store.cueBoard(), waiting: try await store.cueMessagesWaitingForYou(), left: try await store.cueState()?.left ?? [],
      wake: wake, fired: try await fired(of: wake, in: store), schedules: try await store.cueScheduleLines(), language: language,
      quotas: try await store.accountQuotas(on: host), retrying: retrying, related: related)
  }

  private static func fired(of wake: CueWake, in store: CueStore) async throws -> [Fired] {
    guard case .schedule(let fires) = wake else { return [] }
    let lines = try await store.cueLines(fires.map(\.line))
    var fired: [Fired] = []
    for fire in fires {
      guard let line = lines.first(where: { $0.id == fire.line }) else { continue }
      let task = if let id = line.task { try await store.card(id) } else { Card?.none }
      fired.append(Fired(line: line, due: fire.due, task: task))
    }
    return fired
  }

  public static func render(_ input: Input) -> String {
    var lines = ["<cue>", input.now.formatted(stamp) + "（\(zone(input.now))）"]

    lines.append("项目：" + input.projects.map(\.name).joined(separator: "、"))

    lines.append("变化（上次醒来之后\(input.recaps.isEmpty ? "" : "；缩进的是那件事的近况，同 task peek 的结果")）：" + (input.changes.isEmpty ? "无" : ""))
    var shown = Set<Subject>()
    for change in input.changes {
      let subject = Subject(change), recap = subject.flatMap { input.recaps[$0] }
      lines.append("- " + self.change(change, reply: recap == nil))
      guard let subject, let recap, shown.insert(subject).inserted else { continue }
      lines += recap.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }
    }

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

    lines += related(input.related)

    lines.append("醒来：" + wake(input.wake))
    if case .schedule = input.wake { lines += input.fired.map { "- " + fired($0, now: input.now) } }
    if let retrying = input.retrying { lines.append("上一轮出错重试：\(clip(retrying, 160))；先 peek 核对上一轮做到哪，做过的不重做") }
    let tight = input.quotas.compactMap { CueQuotaWords.tightLine($0, at: input.now) }
    if !tight.isEmpty { lines += ["额度吃紧："] + tight.map { "- " + $0 } }
    if let language = input.language { lines.append("这一轮你写下的字都用\(language)（回复、tell、任务、对会话说的话）") }
    lines.append("</cue>")
    return lines.joined(separator: "\n")
  }

  public static func delivered(_ pending: [CueMessage], setAside: [CueMessage], files: AttachmentFiles, imagesAsFiles: Bool) -> String {
    pending.map { message in
      guard message.author == .known(.you) else {
        let question = CueFormat.plainText(message.text).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let noted = message.allowsFromNowOn(message.answer) ? "（已照原话记进重点记忆，不用再记）" : ""
        return "他回答了「\(question)」：\(message.answer ?? "")\(noted)"
      }
      let paths = CueFormat.parse(message.text).compactMap { token in
        AttachmentFiles.agentFile(token, imagesAsFiles: imagesAsFiles).flatMap { files.agentLine(key: $0.key, name: $0.name) }
      }
      let said = ([message.text] + paths).joined(separator: "\n")
      let cards = setAside.filter { $0.setAsideBy == message.id }
      guard !cards.isEmpty else { return said }
      return ([said, "", "（他开口收起了等你里的 \(cards.count) 张；他这句与它无关就 tell 带 restore 放回：）"] + cards.map { "- " + question($0) }).joined(separator: "\n")
    }.joined(separator: "\n\n")
  }

  public static func asked(_ pending: [CueMessage]) -> [String] {
    pending.filter { $0.author == .known(.you) }.map(\.text)
  }

  public static func related(_ found: [String]) -> [String] {
    found.isEmpty ? [] : ["他问的话在会话回复里查到的（按他的词查的，不全；要全用 memory recall）："] + found.map { "- " + $0 }
  }

  public struct Fired: Sendable {
    public var line: CueMemoryLine
    public var due: Date
    public var task: Card?

    public init(line: CueMemoryLine, due: Date, task: Card?) {
      self.line = line
      self.due = due
      self.task = task
    }
  }

  private static func fired(_ fired: Fired, now: Date) -> String {
    let line = fired.line
    var parts = ["\(line.id.uuidString.lowercased()) \(line.text)（\(line.repeats.map(CueScheduleWords.repeats) ?? "一次")）"]
    if let task = fired.task { parts.append("任务「\(task.heading)」（\(task.id.shortID)）") }
    if CueFire.late(fired.due, at: now) { parts.append("本该 \(CueScheduleWords.time(fired.due, now: now))，错过了，现在补上") }
    return parts.joined(separator: " · ")
  }

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

  public enum Subject: Hashable, Sendable {
    case task(UUID)
    case session(String)

    public init?(_ change: CueChange) {
      if let task = change.task {
        self = .task(task.id)
      } else if let session = change.session {
        self = .session(session.sessionID)
      } else {
        return nil
      }
    }
  }

  private static func change(_ change: CueChange, reply: Bool) -> String {
    let label: String =
      switch change.kind {
      case .settled: change.interrupted ? state(.known(.interrupted)) : "歇下"
      case .waitingForUser: "等回答"
      case .failed: "出错"
      case .undelivered: "发送失败"
      case .done: "完成"
      case .stalled: "等子代理 \(Int(SessionState.stallAfter / 60)) 分钟没动静"
      }
    var text = "[\(label)] \(where_(change))"
    if let detail = change.detail, !detail.isEmpty { text += "：\(clip(detail, 120))" }
    if reply, let reply = change.recap?.lastReply { text += " · 回复：\(clip(reply, 160))" }
    return text
  }

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

  static func sessionLine(_ session: SessionState, now: Date, left: [CueLeft] = []) -> String {
    var parts = [sessionName(session), "\(state(session.state)) \(duration(now.timeIntervalSince(session.stateSince)))"]
    if left.contains(where: { $0.holds(for: session) }) { parts.append(leftNote) }
    if let recent = recent(session) { parts.append("近况：\(clip(recent, 80))") }
    return parts.joined(separator: " · ")
  }

  static let leftNote = "新回复"

  static func sessionName(_ session: SessionState) -> String { "会话「\(session.title)」（\(session.shortID)）" }

  private static func leafParts(_ leaf: CueBoardLeaf, named name: String?, now: Date, left: [CueLeft]) -> [String] {
    let state = leaf.session.map { state($0.state) } ?? (leaf.launching ? "正在开会话" : leaf.sending ? "发送中" : "没开工")
    var parts = ["\(name.map { "\($0) › " } ?? "")\(state) \(duration(now.timeIntervalSince(leaf.since)))"]
    if let session = leaf.session, left.contains(where: { $0.holds(for: session) }) { parts.append(leftNote) }
    if let session = leaf.session, let recent = recent(session) { parts.append("近况：\(clip(recent, 80))") }
    return parts
  }

  private static func recent(_ session: SessionState) -> String? {
    if session.state == .known(.waitingForUser), let question = session.question { return question.text }
    if session.state.isWorking, let detail = session.detail { return detail }
    return session.pendingPrompt.map { "在处理：\($0)" }
  }

  static func state(_ state: Open<WorkState>) -> String {
    switch state.known {
    case .thinking, .tool, .compacting: "工作中"
    case .delegating: "等子代理交回"
    case .waitingForUser: "等回答"
    case .settled: "空闲"
    case .error: "出错"
    case .ended: "已结束"
    case .interrupted: "做到一半被打断"
    case nil: state.rawValue
    }
  }

  private static func where_(_ change: CueChange) -> String {
    guard let task = change.task else { return change.session.map(sessionName) ?? "" }
    let base = "\(task.heading)（\(task.id.shortID)）" + (task.status == .done ? "（已完成）" : "")
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

  static func zone(_ date: Date) -> String {
    let offset = TimeZone.current.secondsFromGMT(for: date), minutes = abs(offset) / 60
    return "UTC\(offset < 0 ? "-" : "+")\(minutes / 60)" + (minutes % 60 == 0 ? "" : ":" + String(format: "%02d", minutes % 60))
  }

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

  static var monthDay: Date.VerbatimFormatStyle {
    .init(format: "\(month: .twoDigits)-\(day: .twoDigits)", timeZone: .current, calendar: Calendar(identifier: .gregorian))
  }

  static var fullDay: Date.VerbatimFormatStyle {
    .init(format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)", timeZone: .current, calendar: Calendar(identifier: .gregorian))
  }
}
