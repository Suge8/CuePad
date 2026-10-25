import CueText
import Foundation

extension CueStore {
  /// 写一条对话。正文不能为空。你说的一句同时收起还开着的提问（`CueQuestionEnd`）。带 `ask` 的是 Cue 请你允许的提问（"等你"）：问的是什么（类别、动作、规矩，`CueAsking`）、
  /// 与按范围（关联任务此刻所在的项目）写出的选项（`CueAsk.choices`）一起存下；点名要你看的图（`shots`，`CueShot.checked` 过的）跟着写下。
  /// 点名的图不在发到手机的里抛 `shotMissing`，什么都不写。
  @discardableResult
  public func addCueMessage(
    _ author: CueAuthor, text: String, ask: CueAsking? = nil, shots: [CueShot] = [], urgent: Bool = false, task: UUID? = nil
  ) throws -> CueMessage {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CueStoreError.blankDeliveryContent }
    return try write {
      try checkShots(shots)
      guard let ask else {
        let message = try insertCueMessage(author, text: text, shots: shots, urgent: urgent, task: task)
        if author == .you { _ = try endQuestions(setAsideBy: message.id, where: "1", []) }
        return message
      }
      let project = try projectID(of: task).flatMap { try find(Project.self, $0) }
      return try insertCueMessage(author, text: text, asking: ask, shots: shots, in: project, urgent: urgent, task: task)
    }
  }

  /// 点名的图都在发到手机的里，不在的抛 `shotMissing`（在写事务内调用）。
  func checkShots(_ shots: [CueShot]) throws {
    for shot in shots where try find(PiPreview.self, shot.preview) == nil { throw CueStoreError.shotMissing(shot.preview.uuidString.lowercased()) }
  }

  /// 写一条对话（在写事务内调用）。`asking` 是提问问的什么，`project` 是它的范围，`shots` 是点名要你看的图；`at`：排在对话里的时刻，缺省是此刻（一轮的经过排在这一轮开始的时刻）。
  /// 要提示你的（`CueMessage.alerts`）同时置手机推送标志，到不到你只看 `reaches`。它提到的那几处此刻的样子一并记下（`CuePlace`）。
  func insertCueMessage(
    _ author: CueAuthor, text: String, asking: CueAsking? = nil, shots: [CueShot] = [], in project: Project? = nil, urgent: Bool = false,
    task: UUID? = nil, tools: PiChatMessage.Tools? = nil, wake: CueWake? = nil, at time: Date? = nil
  ) throws -> CueMessage {
    let now = Date.stamp
    var message = CueMessage(
      id: UUID(), author: .known(author), text: text, choices: asking?.ask.choices(in: project?.name),
      asked: asking.map { CueAsked($0.ask, project: project?.id) }, askAction: asking?.action, askRule: asking?.rule, shots: shots,
      urgent: urgent, taskID: task,
      answer: nil, answeredAt: nil, setAsideBy: nil, deliveredAt: nil, createdAt: time ?? now, modifiedAt: now, tools: tools, wake: wake,
      places: try CuePlace.capture(task: task, wake: wake, in: db), notify: false)
    message.notify = try message.alerts && reaches(.cue)
    try insert(message)
    try registerImages(in: text)
    return message
  }

  /// 一轮的经过那一行（值班的管理器写，`CueMessage.tools`）：在这一轮开始的位置写下（`id` 为 nil，返回新行的 id；Cue 自己醒来的一轮醒来时就写，
  /// 带着为什么醒 `wake`，你发起的第一次调工具时写），之后每做完一步、以及这一轮做完时改它的清单与是谁的那一轮（你中途插话，Cue 自己醒来的一轮就成了回答你的）。
  /// 这一轮说的话与结果都在它之后。你发起的写成 `round`；Cue 自己醒来的写成没有正文的动态（`note`），Cue 页里是那一节的第一行。
  @discardableResult
  public func recordCueRound(
    _ id: UUID?, startedAt: Date, answersYou: Bool, tools: PiChatMessage.Tools?, wake: CueWake? = nil
  ) throws -> UUID {
    try write { try putCueRound(id, startedAt: startedAt, answersYou: answersYou, tools: tools, wake: wake) }
  }

  private func putCueRound(_ id: UUID?, startedAt: Date, answersYou: Bool, tools: PiChatMessage.Tools?, wake: CueWake? = nil) throws -> UUID {
    let author: CueAuthor = answersYou ? .round : .note
    guard let id else { return try insertCueMessage(author, text: "", tools: tools, wake: wake, at: startedAt).id }
    try db.run(
      "UPDATE cueMessages SET author = ?1, tools = ?2, modifiedAt = ?3 WHERE id = ?4 AND (author IS NOT ?1 OR tools IS NOT ?2)",
      [author.rawValue, tools?.stored, Date.stamp, id])
    return id
  }

  /// 一轮做完（值班的管理器调）：经过那一行的最终清单（`tools`；没调过工具为 nil，那一行不动）、这一轮写给你的话（`reply`，规则同 `replyCueRound`）
  /// 与歇着（`setCueState`）在同一个事务里写下，返回那一行。"这一轮做完了"只看此刻的状态（`CueState.round`），各端都照它判断：
  /// 分开写的话同步可能先把歇着带到别的设备、话与清单还在路上，那里的 Cue 页就把这一轮先当成没说话，话到了再改回来。
  @discardableResult
  public func finishCueRound(
    _ id: UUID?, startedAt: Date, answersYou: Bool, tools: PiChatMessage.Tools?, reply: String?, as author: CueAuthor, context: CueContext?
  ) throws -> UUID? {
    try write {
      let row = try tools.map { try putCueRound(id, startedAt: startedAt, answersYou: answersYou, tools: $0) } ?? id
      if let reply { try putCueReply(startedAt: startedAt, reply: reply, as: author, answersYou: answersYou) }
      try putCueState(.settled, detail: nil, step: nil, round: nil, context: context)
      return row
    }
  }

  /// 一轮写给你的话（值班的管理器调）：做完时的回复，或回答你的一轮出错。不是在回答你的一轮（`answersYou` 为假）里已经对你说过话
  /// （tell、done 的结果），最后那句只是复述，不写。回答你的一轮要提示你（`urgent`：你说完多半就离开了，在等它），一轮只响一次：
  /// 这一轮已经提示过你（提问卡、急事、出错）就不再提示。
  public func replyCueRound(startedAt: Date, reply: String, as author: CueAuthor, answersYou: Bool) throws {
    try write { try putCueReply(startedAt: startedAt, reply: reply, as: author, answersYou: answersYou) }
  }

  private func putCueReply(startedAt: Date, reply: String, as author: CueAuthor, answersYou: Bool) throws {
    guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let said = try select(CueMessage.self, where: "author = 'cue' AND createdAt >= ?", [startedAt])
    guard answersYou || said.isEmpty else { return }
    _ = try insertCueMessage(author, text: reply, urgent: answersYou && !said.contains(where: \.alerts))
  }

  /// 待交给 Cue 的大脑的（唯一定义，也是它的部分索引的条件），交出去都叫醒它：你说了还没交的话，与还没交、或交过之后又从别处同步来另一个回答的回答。
  static let toDeliver = """
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

  /// Cue 页的新消息（唯一的规则），从早到晚：Cue 对你说的话里，晚于你读到的地方（`CueRead`）与你最近一句的
  /// （答了的提问也算：它在对话里是你那边的一句）。
  /// 带选项的不算：开着时在"等你"里，结束了是你答过的或它撤回的。它自己醒来的动态、一轮的经过不是对你说的话。
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
