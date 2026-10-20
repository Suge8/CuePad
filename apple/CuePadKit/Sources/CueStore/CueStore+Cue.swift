import CryptoKit
import CueText
import Foundation

// MARK: 对话

extension CueStore {
  /// 写一条对话。正文不能为空。你说的一句同时收起还开着的提问（`CueQuestionEnd`）。带 `ask` 的是 Cue 请你允许的提问（"等你"）：问的是什么（类别、动作、规矩，`CueAsking`）、
  /// 范围（关联任务此刻所在的项目，`CueMessage.asked`）与按范围写出的选项（`CueAsk.choices`）一起存下；
  /// 提问点名要你看的图（`shots`，`CueShot.checked` 过的）跟着写下。
  /// 允许清单里有这类事（`CueProfile.allowing`，按同一个项目）就抛 `alreadyAllowed`、点名的图不在发到手机的里抛 `shotMissing`，什么都不写。
  @discardableResult
  public func addCueMessage(
    _ author: CueAuthor, text: String, ask: CueAsking? = nil, shots: [CueShot] = [], urgent: Bool = false, task: UUID? = nil
  ) throws -> CueMessage {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CueStoreError.blankDeliveryContent }
    return try write {
      guard let ask else {
        let message = try insertCueMessage(author, text: text, urgent: urgent, task: task)
        if author == .you { _ = try endQuestions(setAsideBy: message.id, where: "1", []) }
        return message
      }
      let project = try projectID(of: task).flatMap { try find(Project.self, $0) }
      if let allowed = try cueProfile()?.allowing(ask.ask, in: project?.id) {
        throw CueStoreError.alreadyAllowed(try allowed.project.flatMap { try find(Project.self, $0)?.name })
      }
      try checkShots(shots)
      return try insertCueMessage(author, text: text, asking: ask, shots: shots, in: project, urgent: urgent, task: task)
    }
  }

  /// 点名的图都在发到手机的里，不在的抛 `shotMissing`（在写事务内调用）。
  func checkShots(_ shots: [CueShot]) throws {
    for shot in shots where try find(PiPreview.self, shot.preview) == nil { throw CueStoreError.shotMissing(shot.preview.uuidString.lowercased()) }
  }

  /// 写一条对话（在写事务内调用）。`asking` 是提问问的什么，`project` 是它的范围，`shots` 是点名要你看的图；`at`：排在对话里的时刻，缺省是此刻（一轮的经过排在这一轮开始的时刻）。
  /// 要提示你的（`CueMessage.alerts`）同时置手机推送标志，到不到你只看 `reaches`。
  func insertCueMessage(
    _ author: CueAuthor, text: String, asking: CueAsking? = nil, shots: [CueShot] = [], in project: Project? = nil, urgent: Bool = false,
    task: UUID? = nil, tools: PiChatMessage.Tools? = nil, at time: Date? = nil
  ) throws -> CueMessage {
    let now = Date.stamp
    var message = CueMessage(
      id: UUID(), author: .known(author), text: text, choices: asking?.ask.choices(in: project?.name),
      asked: asking.map { CueAllow($0.ask, project: project?.id) }, askAction: asking?.action, askRule: asking?.rule, shots: shots,
      urgent: urgent, taskID: task,
      answer: nil, answeredAt: nil, setAsideBy: nil, deliveredAt: nil, createdAt: time ?? now, modifiedAt: now, tools: tools, notify: false)
    message.notify = try message.alerts && reaches(.cue)
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

  /// 一轮写给你的话（值班的管理器调）：做完时的回复，或回答你的一轮出错。不是在回答你的一轮（`answersYou` 为假）里已经对你说过话
  /// （tell、done 的结果），最后那句只是复述，不写。回答你的一轮要提示你（`urgent`：你说完多半就离开了，在等它），一轮只响一次：
  /// 这一轮已经提示过你（提问卡、急事、出错）就不再提示。
  public func replyCueRound(startedAt: Date, reply: String, as author: CueAuthor, answersYou: Bool) throws {
    guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    try write {
      let said = try select(CueMessage.self, where: "author = 'cue' AND createdAt >= ?", [startedAt])
      guard answersYou || said.isEmpty else { return }
      _ = try insertCueMessage(author, text: reply, urgent: answersYou && !said.contains(where: \.alerts))
    }
  }

  /// Cue 被会话叫醒、看过没动手的那一轮补的一行动态（`note`，灰字、不推送）："看过「会话名」，不打算行动"。
  /// 对话里最后一条就是上一行这样的动态（`after`）就并进去，看过几个会话写成"看过 N 个会话"。返回这一行与它看过的会话。
  public func noteCueGlance(_ sessionIDs: [String], after previous: CueGlance?) throws -> CueGlance {
    try write {
      let last = try select(CueMessage.self, orderBy: "createdAt DESC, rowid DESC", limit: 1).first
      let merging = previous.flatMap { $0.row == last?.id ? $0 : nil }
      var sessions = merging?.sessions ?? []
      for id in sessionIDs where !sessions.contains(id) { sessions.append(id) }
      let title = sessions.count == 1 ? try sessionState(sessions[0])?.title : nil
      let text = "看过" + (title.map { "「\($0)」" } ?? " \(sessions.count) 个会话") + "，不打算行动"
      guard let merging else { return CueGlance(row: try insertCueMessage(.note, text: text).id, sessions: sessions) }
      try db.run("UPDATE cueMessages SET text = ?, modifiedAt = ? WHERE id = ?", [text, Date.stamp, merging.row])
      return CueGlance(row: merging.row, sessions: sessions)
    }
  }

  /// Cue 说的、正文就是 `text` 的最近一条（经过清单里"对你说"那一条点它跳回原处）。
  public func latestCueMessage(saying text: String) throws -> CueMessage? {
    try select(CueMessage.self, where: "author = 'cue' AND text = ?", [text], orderBy: "createdAt DESC, rowid DESC", limit: 1).first
  }

  /// 结束一条还开着的提问（`CueQuestionEnd`）；已经结束的抛 `questionEnded`，回答不是它的选项之一抛 `notAChoice`。回答交给 Cue（`toDeliver`），撤回的不交。
  /// 你选的是第二项（"以后……不用问"，`CueAsk.always(in:)`）时，同一个事务里把提问存的类别与范围（`CueMessage.asked`）记进允许清单；
  /// 清单改了返回真，调用方上传设置。
  @discardableResult
  public func endCueQuestion(_ id: UUID, _ end: CueQuestionEnd) throws -> Bool {
    try write {
      guard let message = try find(CueMessage.self, id) else { throw CueStoreError.notFound }
      if case .answered(let answer) = end, message.choices?.contains(answer) != true { throw CueStoreError.notAChoice(answer) }
      let answer: String? = if case .answered(let text) = end { text } else { nil }
      guard try endQuestions(answer: answer, where: "id = ?", [id]) > 0 else { throw CueStoreError.questionEnded }
      guard case .answered(let answer) = end, let asked = message.asked, let choices = message.choices, choices.count > 1, answer == choices[1]
      else { return false }
      return try changeAllows(asked, allowed: true)
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

  /// 你开口收起的提问（唯一定义，也是它的部分索引的条件）：记着是哪句话收起的（`CueMessage.setAsideBy`）。
  /// 它只随结束写下（`endQuestions`）、随放回清掉（`reopen`），有值就是收起着，不再另看 `answeredAt`。
  static let setAside = "setAsideBy IS NOT NULL"

  /// 结束提问只在这里写：结束的时刻，与你的回答或收起它的那句话（撤回的都没有）。只动 `predicate` 选中的还开着的提问，返回结束了几条。
  /// 必须在写事务内调用。
  private func endQuestions(
    answer: String? = nil, setAsideBy: UUID? = nil, where predicate: String, _ bindings: [any SQLBindable]
  ) throws -> Int {
    let now = Date.stamp
    let values: [any SQLBindable] = [answer, setAsideBy, now, now]
    try db.run(
      "UPDATE cueMessages SET answer = ?, setAsideBy = ?, answeredAt = ?, modifiedAt = ? WHERE \(Self.openQuestion) AND \(predicate)",
      values + bindings)
    return db.changes
  }

  /// 你开口收起的提问（`setAside`，走部分索引），从早到晚：交给 Cue 时列在收起它的那句话后面，Cue 放回时按 id 前缀在里面找。
  public func cueQuestionsSetAside() throws -> [CueMessage] {
    try select(CueMessage.self, where: Self.setAside, orderBy: "createdAt, rowid")
  }

  /// Cue 判断你那句话不是在答这条：放回"等你"。只有你开口收起的放得回（`setAside`），别的抛 `questionEnded`。
  public func restoreCueQuestion(_ id: UUID) throws {
    try write {
      try reopen(where: "id = ?", [id])
      guard db.changes > 0 else { throw CueStoreError.questionEnded }
    }
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

  /// 这些你的消息、"等你"上的回答已交给 Cue 的大脑（Cue 运行的那台 Mac 写）。只记还待交的（`toDeliver`）：已记过的不改，回答在那之后改过的再记一次。
  public func markCueMessagesDelivered(_ ids: [UUID], at time: Date = .now) throws {
    guard !ids.isEmpty else { return }
    try write {
      try db.run(
        "UPDATE cueMessages SET deliveredAt = ?1, modifiedAt = ?2 WHERE id IN (SELECT value FROM json_each(?3)) AND \(Self.toDeliver)",
        [time, Date.stamp, Self.idList(ids)])
    }
  }

  /// 撤回你说的、还没交给 Cue 的一句（重发或移除没回执的话）；返回是否撤回了。已交出去的撤不回（Cue 已经读到）。
  /// 这句收起的提问放回"等你"：Cue 没读到这句，就没人替它判断。
  public func withdrawCueMessage(_ id: UUID) throws -> Bool {
    try write {
      try db.run("DELETE FROM cueMessages WHERE id = ? AND author = 'you' AND deliveredAt IS NULL", [id])
      guard db.changes > 0 else { return false }
      try reopen(where: "setAsideBy = ?", [id])
      return true
    }
  }

  /// 收起的提问放回"等你"（必须在写事务内调用）。
  private func reopen(where predicate: String, _ bindings: [any SQLBindable]) throws {
    try db.run(
      "UPDATE cueMessages SET answeredAt = NULL, setAsideBy = NULL, modifiedAt = ? WHERE \(Self.setAside) AND \(predicate)", [Date.stamp] + bindings)
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

  /// 在等你回答的消息，从早到晚："在等你"就是还开着的提问（`openQuestion`），直到你回答、你开口收起（Cue 可放回）或 Cue 撤回。
  /// 不看关联任务的状态：要问的几类（`CueAsk`）本来就在任务做完之后问（推送、合并、发布），按任务完成算过期会让刚问的那条立刻消失；
  /// 情况变了由 Cue 撤回。
  public func cueMessagesWaitingForYou() throws -> [CueMessage] {
    try select(CueMessage.self, where: Self.openQuestion, orderBy: "createdAt, rowid")
  }

  /// 读到的最近对话（`recent`，从早到晚，同 `cueMessages`）之外问的、在它最早那条之后你答了的提问（撤回的不算）：
  /// 问的那句掉出了读的范围，你的回答还在读到的这段时间里。范围按 id 排除，不按时刻切：同一毫秒写下的几条，`cueMessages` 按 rowid 截，按时刻切会两边都漏掉。
  public func cueQuestionsAnswered(outside recent: [CueMessage]) throws -> [CueMessage] {
    guard let oldest = recent.first else { return [] }
    return try select(
      CueMessage.self, where: "\(Self.answered) AND answeredAt >= ?1 AND createdAt <= ?1 AND id NOT IN (SELECT value FROM json_each(?2))",
      [oldest.createdAt, Self.idList(recent.map(\.id))], orderBy: "createdAt, rowid")
  }

  /// 你答了的提问（撤回的 answer 为空）：也是它的部分索引（`Schema` 第 57 步）的条件，不一样就用不上。
  static let answered = "choices IS NOT NULL AND answer IS NOT NULL"
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

  /// 让 Cue 运行在 `host` 那台 Mac 并启用（另一台上的会停下）——手机与 Mac 同一条规则，按那台写下的能用的 Agent（`MacAgents`）判断：
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

// MARK: 读到哪

extension CueStore {
  /// Cue 页的新消息（唯一的规则），从早到晚：Cue 对你说的话里，晚于你读到的地方（`CueRead`）与你最近一句的
  /// （答了的提问也算：它在对话里是你那边的一句）。
  /// 带选项的不算：开着时在"等你"里，结束了是你答过的或它撤回的。它自己醒来的动态、一轮的经过、交接备忘不是对你说的话。
  public func cueUnread() throws -> [UUID] {
    try db.query(
      """
      SELECT id FROM cueMessages
      WHERE author = 'cue' AND choices IS NULL
        AND createdAt > MAX(
          IFNULL((SELECT modifiedAt FROM cueRead WHERE id = ?1), 0),
          IFNULL((SELECT createdAt FROM cueMessages WHERE author = 'you' ORDER BY createdAt DESC LIMIT 1), 0),
          IFNULL((SELECT MAX(answeredAt) FROM cueMessages WHERE \(Self.answered)), 0))
      ORDER BY createdAt, rowid
      """, [CueRead.recordID]
    ) { $0.uuid(0) }
  }

  /// 读到了写下于 `through` 的那条 Cue 的话：只往后挪，没挪（读过更远的）不写、不同步。
  public func markCueRead(through: Date) throws {
    try write {
      try db.run(
        """
        INSERT INTO cueRead (id, modifiedAt) VALUES (?1, ?2)
        ON CONFLICT(id) DO UPDATE SET modifiedAt = excluded.modifiedAt WHERE excluded.modifiedAt > cueRead.modifiedAt
        """, [CueRead.recordID, through])
    }
  }
}

// MARK: 此刻

extension CueStore {
  /// Cue 此刻在做什么；值班的 Mac 还没写过为 nil。
  public func cueState() throws -> CueState? { try find(CueState.self, CueState.recordID) }

  /// Cue 在值班时的那一份（`CueDuty`：名字与留给你回的会话）；不在值班为 nil。值班按 `CueProfile.onDuty`（各端读同步来的设置、状态与它那台 Mac 的在线记录），
  /// 那台 Mac 的期限到了由订阅重读（`macOnline`），"等你 N"、会话显示与手机推送标志到点自己变。
  public func cueDuty() throws -> CueDuty? {
    guard let profile = try cueProfile(), let host = profile.activeHost else { return nil }
    let state = try cueState()
    guard profile.onDuty(state, hostOnline: try macOnline(host)) else { return nil }
    return CueDuty(name: profile.name, left: state?.left ?? [])
  }

  /// Cue 把会话此刻的这次停下留给你回（`CueLeft`）：会话行显示"待回复"（在等回答的回到等你确认），谁再对它说话就作废。
  /// 会话没停着（在跑、出错、已结束）抛 `notStopped`。顺手去掉已作废的旧条目，表里只留此刻还成立的。返回记录 id（立即上传用）。
  @discardableResult
  public func leaveToYou(_ sessionID: String) throws -> UUID {
    try write {
      guard let session = try sessionState(sessionID) else { throw CueStoreError.notFound }
      guard session.state.known?.isStopped == true else { throw CueStoreError.notStopped(session.title) }
      let current = try cueState()
      let others = current?.left.filter { $0.sessionID != sessionID } ?? []
      let sessions = try select(
        PiSessionState.self, where: "sessionID IN (SELECT value FROM json_each(?))", [JSONColumn.encode(others.map(\.sessionID))])
      let left = others.filter { entry in sessions.contains(where: entry.holds) } + [CueLeft(sessionID: sessionID, since: session.stateSince)]
      let next = CueState(state: current?.state ?? .known(.settled), detail: current?.detail, round: current?.round, woke: current?.woke,
        context: current?.context, left: left, modifiedAt: Date.stamp)
      try db.run(
        """
        INSERT INTO cueState (\(CueState.columns.joined(separator: ", "))) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET leftToYou = excluded.leftToYou, modifiedAt = excluded.modifiedAt
        """, next.bindings)
      return CueState.recordID
    }
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
      let current = try cueState()
      let next = CueState(
        state: .known(state), detail: detail, round: round, woke: woke, context: context, left: current?.left ?? [], modifiedAt: Date.stamp)
      if let current,
        (current.state, current.detail, current.round, current.woke, current.context) == (next.state, next.detail, next.round, next.woke, next.context)
      {
        return
      }
      try db.run(
        """
        INSERT INTO cueState (\(CueState.columns.joined(separator: ", "))) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
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
