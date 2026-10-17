import CryptoKit
import CueText
import Foundation

// MARK: 对话

extension CueStore {
  /// 写一条对话。正文不能为空。带 `ask` 的是 Cue 请你允许的提问（"等你"，选项是 `CueAsk.choices`）：
  /// 允许清单里有这类事（`CueProfile.allowing`，按关联任务所在的项目）就抛 `alreadyAllowed`、什么都不写。
  @discardableResult
  public func addCueMessage(_ author: CueAuthor, text: String, ask: CueAsk? = nil, urgent: Bool = false, task: UUID? = nil) throws -> CueMessage {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CueStoreError.blankDeliveryContent }
    return try write {
      if let ask, let allowed = try cueProfile()?.allowing(ask, in: try projectID(of: task)) {
        throw CueStoreError.alreadyAllowed(try allowed.project.flatMap { try find(Project.self, $0)?.name })
      }
      return try insertCueMessage(author, text: text, choices: ask?.choices, urgent: urgent, task: task)
    }
  }

  /// 写一条对话（在写事务内调用）。`at`：排在对话里的时刻，缺省是此刻（一轮的经过排在这一轮开始的时刻）。
  func insertCueMessage(
    _ author: CueAuthor, text: String, choices: [String]? = nil, urgent: Bool = false, task: UUID? = nil, tools: PiChatMessage.Tools? = nil,
    at time: Date? = nil
  ) throws -> CueMessage {
    let now = Date.stamp
    let message = CueMessage(
      id: UUID(), author: .known(author), text: text, choices: choices, urgent: urgent, taskID: task,
      answer: nil, answeredAt: nil, deliveredAt: nil, createdAt: time ?? now, modifiedAt: now, tools: tools, notify: false)
    try insert(message)
    try registerImages(in: text)
    return message
  }

  /// 一轮的经过那一行（值班的管理器写，`CueMessage.tools`）：这一轮第一次调工具时在它开始的位置写下（`id` 为 nil，返回新行的 id），
  /// 之后每做完一步、以及这一轮做完时改它的清单与是谁的那一轮（你中途插话，Cue 自己醒来的一轮就成了回答你的）。
  /// 这一轮说的话与结果都在它之后。你发起的写成 `round`；Cue 自己醒来的写成没有正文的动态（`note`），跟着动态收起。
  @discardableResult
  public func recordCueRound(_ id: UUID?, startedAt: Date, answersYou: Bool, tools: PiChatMessage.Tools?) throws -> UUID {
    let author: CueAuthor = answersYou ? .round : .note
    return try write {
      guard let id else { return try insertCueMessage(author, text: "", tools: tools, at: startedAt).id }
      try db.run(
        "UPDATE cueMessages SET author = ?1, tools = ?2, modifiedAt = ?3 WHERE id = ?4 AND (author IS NOT ?1 OR tools IS NOT ?2)",
        [author.rawValue, tools?.stored, Date.stamp, id])
      return id
    }
  }

  /// 一轮做完时它的回复（值班的管理器调）：不是在回答你的一轮（`answersYou` 为假）里已经对你说过话（tell、done 的结果），最后那句只是复述，不写。
  public func replyCueRound(startedAt: Date, reply: String, as author: CueAuthor, answersYou: Bool) throws {
    guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    try write {
      let told = try db.first("SELECT 1 FROM cueMessages WHERE author = 'cue' AND createdAt >= ? LIMIT 1", [startedAt]) { _ in true } ?? false
      guard answersYou || !told else { return }
      _ = try insertCueMessage(author, text: reply)
    }
  }

  /// Cue 说的、正文就是 `text` 的最近一条（经过清单里"对你说"那一条点它跳回原处）。
  public func latestCueMessage(saying text: String) throws -> CueMessage? {
    try select(CueMessage.self, where: "author = 'cue' AND text = ?", [text], orderBy: "createdAt DESC, rowid DESC", limit: 1).first
  }

  /// 结束一条还开着的提问（`CueQuestionEnd`）；已经结束的抛 `questionEnded`。回答交给 Cue（`toDeliver`），撤回的不交。
  /// 你选"以后……都不用问"（`CueAsk.always`）时，同一个事务里把这类事记进允许清单（关联任务在项目里时只管这个项目）；
  /// 清单改了返回真，调用方上传设置。
  @discardableResult
  public func endCueQuestion(_ id: UUID, _ end: CueQuestionEnd) throws -> Bool {
    try write {
      guard try endQuestions(end, where: "id = ?", [id]) > 0 else {
        throw try find(CueMessage.self, id) == nil ? CueStoreError.notFound : CueStoreError.questionEnded
      }
      guard case .answered(let answer) = end, let ask = CueAsk.allCases.first(where: { $0.always == answer }),
        let message = try find(CueMessage.self, id)
      else { return false }
      return try changeAllows(CueAllow(ask, project: try projectID(of: message.taskID)), allowed: true)
    }
  }

  /// 允许清单加上或去掉一项（卡片、设置的开关与 Cue 的 `memory allow` 都经这里）；规矩那一类不能放行，抛 `cannotAllowRule`。
  /// 返回清单改了没有（改了调用方上传设置）。没有设置就从默认值建一行（同 `updateCueProfile`）。
  @discardableResult
  public func setCueAllow(_ allow: CueAllow, allowed: Bool) throws -> Bool {
    try write { try changeAllows(allow, allowed: allowed) }
  }

  private func changeAllows(_ allow: CueAllow, allowed: Bool) throws -> Bool {
    guard allow.ask != .known(.rule) else { throw CueStoreError.cannotAllowRule }
    let before = try cueProfile()?.allows ?? []
    let after = allowed ? before.union([allow]) : before.subtracting([allow])
    guard after != before else { return false }
    _ = try editProfile { $0.allows = after }
    return true
  }

  /// 任务所在的项目；没有任务或任务不在项目里为 nil。
  private func projectID(of task: UUID?) throws -> UUID? {
    try task.flatMap { try find(Card.self, $0) }?.projectID
  }

  /// 还开着的提问（唯一定义）：Cue 带选项问的、还没结束。
  static let openQuestion = "author = 'cue' AND choices IS NOT NULL AND answeredAt IS NULL"

  /// 结束提问只在这里写：结束的时刻与你的回答（撤回的没有）。只动 `predicate` 选中的还开着的提问，返回结束了几条。必须在写事务内调用。
  func endQuestions(_ end: CueQuestionEnd, where predicate: String, _ bindings: [any SQLBindable]) throws -> Int {
    let now = Date.stamp
    let answer: String? = if case .answered(let text) = end { text } else { nil }
    let values: [any SQLBindable] = [answer, now, now]
    try db.run(
      "UPDATE cueMessages SET answer = ?, answeredAt = ?, modifiedAt = ? WHERE \(Self.openQuestion) AND \(predicate)", values + bindings)
    return db.changes
  }

  /// 待交给 Cue 的大脑的（唯一定义），交出去都叫醒它：你说了还没交的话，与还没交、或交过之后又从别处同步来另一个回答的回答。
  private static let toDeliver = """
    ((author = 'you' AND deliveredAt IS NULL)
      OR (author = 'cue' AND answer IS NOT NULL AND (deliveredAt IS NULL OR deliveredAt < answeredAt)))
    """

  /// 待交给 Cue 的大脑的你的消息与回答（`toDeliver`），从早到晚。
  public func cueMessagesToDeliver() throws -> [CueMessage] {
    try select(CueMessage.self, where: Self.toDeliver, orderBy: "createdAt, rowid")
  }

  /// 这些你的消息、"等你"上的回答已交给 Cue 的大脑（Cue 住的那台 Mac 写）。只记还待交的（`toDeliver`）：已记过的不改，回答在那之后改过的再记一次。
  public func markCueMessagesDelivered(_ ids: [UUID], at time: Date = .now) throws {
    guard !ids.isEmpty else { return }
    try write {
      try db.run(
        "UPDATE cueMessages SET deliveredAt = ?1, modifiedAt = ?2 WHERE id IN (SELECT value FROM json_each(?3)) AND \(Self.toDeliver)",
        [time, Date.stamp, Self.idList(ids)])
    }
  }

  /// 撤回你说的、还没交给 Cue 的一句（重发或移除没回执的话）；返回是否撤回了。已交出去的撤不回（Cue 已经读到）。
  public func withdrawCueMessage(_ id: UUID) throws -> Bool {
    try write {
      try db.run("DELETE FROM cueMessages WHERE id = ? AND author = 'you' AND deliveredAt IS NULL", [id])
      return db.changes > 0
    }
  }

  /// 交出去的这些没被 Cue 读完（大脑在那一轮中途退出）：清掉送达，下一个大脑重新交。
  public func unmarkCueMessagesDelivered(_ ids: [UUID]) throws {
    guard !ids.isEmpty else { return }
    try write {
      try db.run(
        "UPDATE cueMessages SET deliveredAt = NULL, modifiedAt = ?1 WHERE id IN (SELECT value FROM json_each(?2)) AND deliveredAt IS NOT NULL",
        [Date.stamp, Self.idList(ids)])
    }
  }

  /// 要推到手机：置推送标志（值班的 Mac 按通知规则调用；见 `CueMessage.notify`）。
  public func flagCueMessageForPush(_ id: UUID) throws {
    try write {
      try db.run(
        "UPDATE cueMessages SET notify = ?1, modifiedAt = ?2 WHERE id = ?3 AND notify IS NULL", [CueMessage.notifyFlag, Date.stamp, id])
    }
  }

  /// 最近的 `limit` 条对话，从早到晚。
  public func cueMessages(limit: Int = 200) throws -> [CueMessage] {
    try select(CueMessage.self, orderBy: "createdAt DESC, rowid DESC", limit: limit).reversed()
  }

  /// 新上下文从哪接上（唯一规则）：最近一份交接备忘与它之后的对话（你的话、Cue 的话、动态），从早到晚，只取最近的 `limit` 条；
  /// 没写过交接就从头算。界面在交接处画"换了新上下文"的分隔，说的是分隔以下都在 Cue 眼前：新班次第一次醒来把这些交给大脑（`CueKeeper`），这句话才一直成立。
  public func cueResume(limit: Int) throws -> CueResume {
    let handoff = try select(CueMessage.self, where: "author = 'handoff'", orderBy: "createdAt DESC, rowid DESC", limit: 1).first
    let after = try select(
      CueMessage.self, where: "author IN ('you', 'cue', 'note') AND text != '' AND createdAt > ?", [handoff?.createdAt ?? .distantPast],
      orderBy: "createdAt DESC, rowid DESC", limit: limit + 1)
    return CueResume(handoff: handoff, messages: after.prefix(limit).reversed(), truncated: after.count > limit)
  }

  /// 在等你回答的消息，从早到晚："在等你"就是还开着的提问（`openQuestion`），直到你回答或 Cue 撤回。
  /// 不看关联任务的状态：要问的几类（`CueAsk`）本来就在任务做完之后问（推送、合并、发布），按任务完成算过期会让刚问的那条立刻消失；
  /// 情况变了由 Cue 撤回。
  public func cueMessagesWaitingForYou() throws -> [CueMessage] {
    try select(CueMessage.self, where: Self.openQuestion, orderBy: "createdAt, rowid")
  }
}

// MARK: 记忆

extension CueStore {
  private static let lineOrder = "createdAt, id"

  /// 记一条。记不成一条的（`CueMemoryLine.fits`：空白、超过 `CueMemoryLine.maxBytes` 字节）拒绝。返回这一条与它的序号。
  @discardableResult
  public func noteCueLine(
    _ text: String, source: CueLineSource, pinned: Bool = false, remindAt: Date? = nil
  ) throws -> (line: CueMemoryLine, index: Int) {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw CueStoreError.blankTaskContent }
    guard CueMemoryLine.fits(text) else { throw CueStoreError.memoryLineTooLong(CueMemoryLine.maxBytes) }
    return try write {
      let line = try insertLine(text, source: source, pinned: pinned, remindAt: remindAt)
      return (line, try index(of: line))
    }
  }

  /// 记一条（在写事务内调用，调用方先查过记得成）。
  private func insertLine(_ text: String, source: CueLineSource, pinned: Bool, remindAt: Date? = nil) throws -> CueMemoryLine {
    let now = Date.stamp
    let line = CueMemoryLine(
      id: UUID(), text: text, pinned: pinned, source: .known(source), remindAt: remindAt, createdAt: now, modifiedAt: now, deletedAt: nil)
    try insert(line)
    return line
  }

  /// 第 `index` 条（按序号，含忘掉的）；没有为 nil。
  public func cueLine(at index: Int) throws -> CueMemoryLine? {
    guard index >= 0 else { return nil }
    return try select(CueMemoryLine.self, orderBy: Self.lineOrder, limit: 1, offset: index).first
  }

  public func cueLine(_ id: UUID) throws -> CueMemoryLine? { try find(CueMemoryLine.self, id) }

  /// 一条的序号。
  public func cueLineIndex(_ id: UUID) throws -> Int? {
    try find(CueMemoryLine.self, id).map(index(of:))
  }

  private func index(of line: CueMemoryLine) throws -> Int {
    try db.first(
      "SELECT count(*) FROM cueLines WHERE createdAt < ?1 OR (createdAt = ?1 AND id < ?2)", [line.createdAt, line.id]
    ) { Int($0.int(0)) } ?? 0
  }

  /// 忘掉一条（软删，位置不变）；覆盖它的摘要随之作废（摘要的指纹含各行忘没忘，见 `cueMemory`）。已忘掉的不变。
  public func forgetCueLine(_ id: UUID) throws {
    try write {
      guard let line = try find(CueMemoryLine.self, id) else { throw CueStoreError.notFound }
      guard line.deletedAt == nil else { return }
      let now = Date.stamp
      try db.run("UPDATE cueLines SET deletedAt = ?1, modifiedAt = ?1 WHERE id = ?2", [now, id])
    }
  }

  /// 一直记着，或取消。
  public func pinCueLine(_ id: UUID, _ pinned: Bool) throws {
    try write {
      try db.run("UPDATE cueLines SET pinned = ?, modifiedAt = ? WHERE id = ? AND pinned != ?", [pinned, Date.stamp, id, pinned])
      guard try find(CueMemoryLine.self, id) != nil else { throw CueStoreError.notFound }
    }
  }

  /// 提醒叫醒过了：清掉它的时刻。
  public func clearCueReminder(_ id: UUID) throws {
    try write { try db.run("UPDATE cueLines SET remindAt = NULL, modifiedAt = ? WHERE id = ? AND remindAt IS NOT NULL", [Date.stamp, id]) }
  }

  /// 到点了的提醒（`remindAt` 不晚于 `now`、没忘掉），最早的在前。
  public func dueCueReminders(at now: Date = .now) throws -> [CueMemoryLine] {
    try select(CueMemoryLine.self, where: "remindAt IS NOT NULL AND remindAt <= ? AND deletedAt IS NULL", [now], orderBy: "remindAt, id")
  }

  /// 下一个还没到点的提醒时刻；没有为 nil。管理器据此排下一次叫醒。
  public func nextCueReminder(after now: Date = .now) throws -> Date? {
    try db.first("SELECT MIN(remindAt) FROM cueLines WHERE remindAt > ? AND deletedAt IS NULL", [now]) { $0.dateOrNil(0) } ?? nil
  }

  /// 全部记忆与有效的摘要，一次读出。摘要写下时区间里各行的 id 与忘没忘记成指纹，现在对不上（别处同步来更早的行、
  /// 本机或别的设备忘掉了其中一行，哪怕忘掉的时刻早于摘要、同步晚到）就作废。
  public func cueMemory() throws -> CueMemory {
    let lines = try select(CueMemoryLine.self, orderBy: Self.lineOrder)
    let summaries = try db.query("SELECT lo, hi, text, lineIDs, createdAt FROM cueSummaries ORDER BY lo, hi") { row in
      (summary: CueMemorySummary(lo: Int(row.int(0)), hi: Int(row.int(1)), text: row.text(2), createdAt: row.date(4)), ids: row.text(3))
    }
    let valid = summaries.filter { entry in
      let (lo, hi) = (entry.summary.lo, entry.summary.hi)
      guard lo >= 0, hi <= lines.count, lo < hi else { return false }
      return Self.fingerprint(lines[lo..<hi]) == entry.ids
    }
    return CueMemory(lines: lines, summaries: valid.map(\.summary))
  }

  /// 记忆的版本读数（`CueMemoryVersion`）：两条聚合，不读行的内容。
  public func cueMemoryVersion() throws -> CueMemoryVersion {
    let lines = try db.first("SELECT count(*), MAX(modifiedAt) FROM cueLines") { (Int($0.int(0)), $0.dateOrNil(1)) } ?? (0, nil)
    let summaries = try db.first("SELECT count(*), MAX(createdAt) FROM cueSummaries") { (Int($0.int(0)), $0.dateOrNil(1)) } ?? (0, nil)
    return CueMemoryVersion(lines: lines.0, linesModifiedAt: lines.1, summaries: summaries.0, summariesWrittenAt: summaries.1)
  }

  /// 写区间 [lo, hi) 的摘要（覆盖旧的）：对齐的 2 的幂区间（至少两行），行要都在；摘要同一条记忆的长度上限。
  public func setCueSummary(lo: Int, hi: Int, text: String) throws {
    let size = hi - lo
    guard lo >= 0, size >= 2, size & (size - 1) == 0, lo % size == 0 else { throw CueStoreError.invalidSummaryRange }
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw CueStoreError.blankTaskContent }
    guard CueMemoryLine.fits(text) else { throw CueStoreError.memoryLineTooLong(CueMemoryLine.maxBytes) }
    try write {
      let lines = try select(CueMemoryLine.self, orderBy: Self.lineOrder, limit: size, offset: lo)
      guard lines.count == size else { throw CueStoreError.invalidSummaryRange }
      try db.run(
        """
        INSERT INTO cueSummaries (lo, hi, text, lineIDs, createdAt) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(lo, hi) DO UPDATE SET text = excluded.text, lineIDs = excluded.lineIDs, createdAt = excluded.createdAt
        """, [lo, hi, text, Self.fingerprint(lines[...]), Date.stamp])
    }
  }

  private static func fingerprint(_ lines: ArraySlice<CueMemoryLine>) -> String {
    SHA256.hash(data: Data(lines.map { $0.id.uuidString + ($0.deletedAt == nil ? "" : "-") }.joined(separator: ",").utf8)).prefix(12).hex
  }

}

// MARK: 设置

extension CueStore {
  /// Cue 的设置；从没设过为 nil。
  public func cueProfile() throws -> CueProfile? { try find(CueProfile.self, CueProfile.recordID) }

  /// 改设置（没有就从默认值建一行）；返回改后的。读、改、写在同一个事务里，`edit` 可按读到的最新值决定改不改；什么都没改就不写。
  @discardableResult
  public func updateCueProfile(_ edit: @Sendable (inout CueProfile) -> Void) throws -> CueProfile {
    try write { try editProfile(edit) }
  }

  /// 让 Cue 住在 `host` 那台 Mac 并启用（另一台上的会停下）——手机与 Mac 同一条规则，按那台写下的能用的 Agent（`MacAgents`）判断：
  /// 选的 Agent 那台用不了才换成 `CueProfile.runtimes` 里第一家能用的，模型属于原来那家、一并清掉；强度留着（运行时自己取档）。
  /// 那台一家都不能用时抛 `CueEnableError`，带上各家为什么。
  public func enableCue(on host: String) throws {
    try write {
      let usable = try macAgents(on: host)
      let available = CueProfile.runtimes.filter(usable.kinds.contains)
      guard let first = available.first else { throw CueEnableError.noRuntime(usable.whyNone) }
      _ = try editProfile { profile in
        profile.hostID = host
        profile.enabledAt = .now
        if profile.runtime.known.map(available.contains) != true {
          profile.runtime = .known(first)
          profile.model = nil
        }
      }
    }
  }

  /// `updateCueProfile` 的事务内部分：必须在写事务内调用。
  private func editProfile(_ edit: (inout CueProfile) -> Void) throws -> CueProfile {
    let stored = try cueProfile()
    var profile = stored ?? CueProfile()
    edit(&profile)
    if let stored, profile == stored { return stored }
    profile.modifiedAt = Date.stamp
    try db.run(
      """
      INSERT INTO cueProfile (\(CueProfile.columns.joined(separator: ", "))) VALUES (\(CueProfile.columns.map { _ in "?" }.joined(separator: ", ")))
      ON CONFLICT(id) DO UPDATE SET \(CueProfile.columns.dropFirst().map { "\($0) = excluded.\($0)" }.joined(separator: ", "))
      """, profile.bindings)
    return profile
  }
}

// MARK: 此刻

extension CueStore {
  /// Cue 此刻在做什么；值班的 Mac 还没写过为 nil。
  public func cueState() throws -> CueState? { try find(CueState.self, CueState.recordID) }

  /// Cue 在值班（`CueProfile.onDuty`，各端读同步来的设置、状态与它那台 Mac 的在线记录）。那台 Mac 的期限到了由订阅重读（`macOnline`），
  /// "等你 N"、会话显示与手机推送标志到点自己变。
  public func cueOnDuty() throws -> Bool {
    guard let profile = try cueProfile(), let host = profile.activeHost else { return false }
    return profile.onDuty(try cueState(), hostOnline: try macOnline(host))
  }

  /// 你最近一句对 Cue 说的话：写下的时刻与交给它的时刻；你还没说过为 nil。到哪了由读的人按此刻推（`Speech.trip`，
  /// App 的"此刻"只在 `SpeechClock` 一处到点刷新），这里只给记录。不说 Cue 那台 Mac 在不在（那是 `macOnline`）。
  public func cueLastYou() throws -> (said: Date, delivered: Date?)? {
    try db.first("SELECT createdAt, deliveredAt FROM cueMessages WHERE author = 'you' ORDER BY createdAt DESC, rowid DESC LIMIT 1") {
      (said: $0.date(0), delivered: $0.dateOrNil(1))
    }
  }

  /// 值班的 Mac 写下 Cue 此刻的样子（在做什么、这个班次的上下文），整行一次写；和库里一样就不写（不触发同步）。不在值班写歇着、没有上下文。
  public func setCueState(
    _ state: PiWorkState, detail: String? = nil, round: UUID? = nil, woke: CueWoke? = nil, context: CueContext? = nil
  ) throws {
    try write {
      let next = CueState(state: .known(state), detail: detail, round: round, woke: woke, context: context, modifiedAt: Date.stamp)
      if let current = try cueState(),
        (current.state, current.detail, current.round, current.woke, current.context) == (next.state, next.detail, next.round, next.woke, next.context)
      {
        return
      }
      try db.run(
        """
        INSERT INTO cueState (\(CueState.columns.joined(separator: ", "))) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET state = excluded.state, detail = excluded.detail, modifiedAt = excluded.modifiedAt, round = excluded.round,
          woke = excluded.woke, context = excluded.context
        """, next.bindings)
    }
  }
}

// MARK: 回想

/// `CueStore.recallCue` 的结果：命中的记忆（带序号）、对话与灵感任务。
public struct CueRecall: Equatable, Sendable {
  public var lines: [CueIndexedLine]
  public var messages: [CueMessage]
  public var cards: [Card]
}

/// 一条记忆与它的序号。
public struct CueIndexedLine: Equatable, Sendable {
  public var index: Int
  public var line: CueMemoryLine

  public init(index: Int, line: CueMemoryLine) {
    self.index = index
    self.line = line
  }
}

extension CueStore {
  /// 全文找：记忆（含忘掉的，标着）、对话、灵感与任务（同 `search`）。每个词都要命中，不分大小写；每类至多 `limit` 条，最近的在前。
  public func recallCue(_ query: String, limit: Int = 20) throws -> CueRecall {
    let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !words.isEmpty else { return CueRecall(lines: [], messages: [], cards: []) }
    let like = words.map { _ in "text LIKE ? ESCAPE '\\'" }.joined(separator: " AND ")
    let patterns: [any SQLBindable] = words.map {
      "%" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
    }
    let lines = try db.query(
      """
      SELECT * FROM (SELECT \(CueMemoryLine.columns.joined(separator: ", ")), ROW_NUMBER() OVER (ORDER BY createdAt, id) - 1 FROM cueLines)
      WHERE \(like) ORDER BY createdAt DESC, id DESC LIMIT \(limit)
      """, patterns
    ) { row in CueIndexedLine(index: Int(row.int(Int32(CueMemoryLine.columns.count))), line: CueMemoryLine(row: row)) }
    let messages = try select(CueMessage.self, where: like, patterns, orderBy: "createdAt DESC, rowid DESC", limit: limit)
    let cards = try search(SearchQuery(text: query), limit: limit).cards
    return CueRecall(lines: lines, messages: messages, cards: cards)
  }
}
