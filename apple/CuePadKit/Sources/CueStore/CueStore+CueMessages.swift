import CueText
import Foundation

extension CueStore {
  /// 你说的一句同时收起还开着的提问（`CueQuestionEnd`）。点名的图不在发到手机的里抛 `shotMissing`，什么都不写。
  @discardableResult
  public func addCueMessage(
    _ author: CueAuthor, text: String, ask: CueAsking? = nil, shots: [CueShot] = [], urgent: Bool = false, task: UUID? = nil, answeredRequests: [UUID]? = [], id: UUID = UUID()
  ) throws -> CueMessage {
    try write {
      try putCueMessage(author, text: text, ask: ask, shots: shots, urgent: urgent, task: task, answeredRequests: answeredRequests, id: id)
    }
  }

  /// 调用者持有写事务，正文、附件校验及收起旧提问与记录写入不可分开。
  func putCueMessage(
    _ author: CueAuthor, text: String, ask: CueAsking? = nil, shots: [CueShot] = [], urgent: Bool = false,
    task: UUID? = nil, answeredRequests: [UUID]? = [], id: UUID = UUID()
  ) throws -> CueMessage {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CueStoreError.blankDeliveryContent }
    try checkShots(shots)
    guard let ask else {
      let message = try insertCueMessage(author, text: text, shots: shots, urgent: urgent, task: task, answeredRequests: answeredRequests, id: id)
      if author == .you { _ = try endQuestions(setAsideBy: message.id, where: "1", []) }
      return message
    }
    let project = try projectID(of: task).flatMap { try find(Project.self, $0) }
    return try insertCueMessage(author, text: text, asking: ask, shots: shots, in: project, urgent: urgent, task: task, answeredRequests: answeredRequests, id: id)
  }

  @discardableResult
  public func addCueMessage(_ author: CueAuthor, shown: ShownText, urgent: Bool = false) throws -> CueMessage {
    try write { try insertCueMessage(author, shown: shown, urgent: urgent) }
  }

  /// 点名的图都在发到手机的里，不在的抛 `shotMissing`（在写事务内调用）。
  func checkShots(_ shots: [CueShot]) throws {
    for shot in shots where try find(PreviewItem.self, shot.preview) == nil { throw CueStoreError.shotMissing(shot.preview.uuidString.lowercased()) }
  }

  /// Cue 写下的置手机推送标志：要提示你的（`CueMessage.alerts`）且到得了你（`reaches`）出可见通知，其余静默叫醒（`CuePush`）。它提到的那几处此刻的样子一并记下（`CuePlace`）。
  func insertCueMessage(
    _ author: CueAuthor, text: String = "", shown: ShownText? = nil, asking: CueAsking? = nil, shots: [CueShot] = [], in project: Project? = nil,
    urgent: Bool = false, task: UUID? = nil, tools: ChatMessage.Tools? = nil, wake: CueWake? = nil, at time: Date? = nil, answeredRequests: [UUID]? = [], id: UUID = UUID()
  ) throws -> CueMessage {
    let now = Date.stamp
    var message = CueMessage(
      id: id, author: .known(author), text: shown?.text ?? text, shownText: shown, choices: asking?.ask.choices(in: project?.name),
      asked: asking.map { CueAsked($0.ask, project: project?.id) }, askAction: asking?.action, askRule: asking?.rule, shots: shots,
      urgent: urgent, taskID: task,
      answer: nil, answeredAt: nil, setAsideBy: nil, deliveredAt: nil, createdAt: time ?? now, modifiedAt: now, tools: tools, answeredRequests: author == .cue ? answeredRequests : nil, wake: wake,
      places: try CuePlace.capture(task: task, wake: wake, project: asking == nil ? nil : project?.id, in: db), notify: nil)
    if author == .cue { message.notify = try message.alerts && reaches(.cue) ? .alert : .wake }
    try insert(message)
    try registerAttachments(in: text)
    return message
  }

  /// 值班的管理器写，在这一轮开始的位置写下，之后每做完一步、以及这一轮做完时改它的清单与是谁的那一轮（你中途插话，Cue 自己醒来的一轮就成了回答你的）。你发起的写成 `round`；Cue 自己醒来的写成没有正文的 `note`。
  @discardableResult
  public func recordCueRound(
    _ id: UUID?, startedAt: Date, answersYou: Bool, tools: ChatMessage.Tools?, wake: CueWake? = nil
  ) throws -> UUID {
    try write { try putCueRound(id, startedAt: startedAt, answersYou: answersYou, tools: tools, wake: wake) }
  }

  private func putCueRound(_ id: UUID?, startedAt: Date, answersYou: Bool, tools: ChatMessage.Tools?, wake: CueWake? = nil) throws -> UUID {
    let author: CueAuthor = answersYou ? .round : .note
    guard let id else { return try insertCueMessage(author, text: "", tools: tools, wake: wake, at: startedAt).id }
    try db.run(
      "UPDATE cueMessages SET author = ?1, tools = ?2, modifiedAt = ?3 WHERE id = ?4 AND (author IS NOT ?1 OR tools IS NOT ?2)",
      [author.rawValue, tools?.stored, Date.stamp, id])
    return id
  }

  /// 清单、最终回复和歇着在同一事务写下，避免界面先看到歇着、后看到回答。没有正文时已接走的请求集合保存到经过行，返回该行 ID。CueKeeper 准备换大脑重跑的一轮只结束本轮，不把待重交请求记成已回答。
  @discardableResult
  public func finishCueRound(
    _ id: UUID?, startedAt: Date, answersYou: Bool, tools: ChatMessage.Tools?, reply: String?, as author: CueAuthor, context: CueContext?, answeredRequests: [UUID] = [], hostID: String? = nil, bootID: String? = nil
  ) throws -> UUID? {
    try write {
      var row = try tools.map { try putCueRound(id, startedAt: startedAt, answersYou: answersYou, tools: $0) } ?? id
      let answer = try reply.flatMap { try putCueReply(startedAt: startedAt, reply: $0, as: author, answersYou: answersYou, answeredRequests: answeredRequests) }
      if answer == nil {
        row = try putCueRound(row, startedAt: startedAt, answersYou: answersYou, tools: tools)
        try db.run("UPDATE cueMessages SET answeredRequests = ?, modifiedAt = ? WHERE id = ?", [JSONColumn.encode(answeredRequests), Date.stamp, row])
      }
      try putCueState(.settled, detail: nil, step: nil, round: nil, context: context, hostID: hostID, bootID: bootID)
      return row
    }
  }

  /// 不是在回答你的一轮（`answersYou` 为假）里已经对你说过话（tell、done 的结果），最后那句只是复述，不写。回答你的一轮要提示你（`urgent`：你说完多半就离开了，在等它），一轮只响一次：这一轮已经提示过你（提问卡、急事、出错）就不再提示。
  public func replyCueRound(startedAt: Date, reply: ShownText, as author: CueAuthor, answersYou: Bool, answeredRequests: [UUID] = []) throws {
    try write { _ = try putCueReply(startedAt: startedAt, reply: "", shown: reply, as: author, answersYou: answersYou, answeredRequests: answeredRequests) }
  }

  private func putCueReply(startedAt: Date, reply: String, shown: ShownText? = nil, as author: CueAuthor, answersYou: Bool, answeredRequests: [UUID]? = []) throws -> UUID? {
    guard !(shown?.text ?? reply).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let said = try select(CueMessage.self, where: "author = 'cue' AND createdAt >= ?", [startedAt])
    guard answersYou || said.isEmpty else { return nil }
    return try insertCueMessage(author, text: reply, shown: shown, urgent: answersYou && !said.contains(where: \.alerts), answeredRequests: answeredRequests).id
  }

  /// 待交给 Cue 的大脑的（唯一定义，也是它的部分索引的条件），交出去都叫醒它：你说了还没交的话，与还没交、或交过之后又从别处同步来另一个回答的回答。
  static let toDeliver = """
    ((author = 'you' AND deliveredAt IS NULL)
      OR (author = 'cue' AND answer IS NOT NULL AND (deliveredAt IS NULL OR deliveredAt < answeredAt)))
    """

  public func cueMessagesToDeliver() throws -> [CueMessage] {
    try select(CueMessage.self, where: Self.toDeliver, orderBy: "createdAt, rowid")
  }

  /// 只记还待交的：已记过的不改，回答在那之后改过的再记一次。
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

  /// 交给 Cue 之后还没有一条 Cue 的话答它的（你的话、交过的回答）：值班一上班就退回重新交（`CueKeeper.run`），上一次值班崩溃、换到别的 Mac 都不丢。
  /// 答它的那条（`answeredRequests` 列着它）要写在最近这次送达之后：退回重交过的，之前那条（出错、换家时说的）不算答上。
  /// 从最早一句被答上的话送达起算：更早的是还不记答了谁时（结构 92 之前）交的，答没答上认不出。
  public func cueMessagesUnanswered() throws -> [UUID] {
    try db.query(
      """
      WITH answered AS (
        SELECT lower(j.value) AS id, max(r.modifiedAt) AS at FROM cueMessages r, json_each(r.answeredRequests) j
        WHERE r.author = 'cue' AND r.answeredRequests IS NOT NULL GROUP BY lower(j.value)),
      since AS (SELECT COALESCE(min(m.deliveredAt), 0) AS at FROM cueMessages m JOIN answered a ON a.id = m.id)
      SELECT m.id FROM cueMessages m LEFT JOIN answered a ON a.id = m.id, since
      WHERE m.deliveredAt IS NOT NULL AND m.deliveredAt >= since.at AND (a.at IS NULL OR a.at < m.deliveredAt)
        AND (m.author = 'you' OR (m.author = 'cue' AND m.answer IS NOT NULL AND m.deliveredAt >= m.answeredAt))
      """
    ) { $0.uuid(0) }
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

  public func cueMessages(limit: Int = 200) throws -> [CueMessage] {
    try select(CueMessage.self, orderBy: "createdAt DESC, rowid DESC", limit: limit).reversed()
  }

  /// Cue 页的新消息（唯一的规则），从早到晚：Cue 对你说的话里，晚于你读到的地方（`CueRead`）与你最近一句的
  /// （答了的提问也算：它在对话里是你那边的一句）。
  /// 带选项的不算：开着时在"等你"里，结束了是你答过的或它撤回的。它自己醒来的一轮的经过不是对你说的话。
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
