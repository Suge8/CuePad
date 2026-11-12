import CueText
import Foundation

extension CueStore {
  /// 已经结束的抛 `questionEnded`，回答不是它的选项之一抛 `notAChoice`。回答交给 Cue（`toDeliver`），撤回的不交。
  /// 你选的是第二项（“以后……不用问”）时，同一个事务里把你看到的那句记成一条你说的重点：不用先问的例外只在记忆里，Cue 读到就直接做。已有一字不差、没忘掉的那条就用它（没钉上的钉上），同一句不记第二遍。返回记下的那一条的 id（调用方连同提问一起上传）。
  @discardableResult
  public func endCueQuestion(_ id: UUID, _ end: CueQuestionEnd) throws -> UUID? {
    try write {
      guard let message = try find(CueMessage.self, id) else { throw CueStoreError.notFound }
      if case .answered(let answer) = end, message.choices?.contains(answer) != true { throw CueStoreError.notAChoice(answer) }
      let answer: String? = if case .answered(let text) = end { text } else { nil }
      guard try endQuestions(answer: answer, where: "id = ?", [id]) > 0 else { throw CueStoreError.questionEnded }
      guard let answer, message.allowsFromNowOn(answer) else { return nil }
      return try keepLine(message.shownChoice(answer))
    }
  }

  private func keepLine(_ text: String) throws -> UUID {
    guard let id = try db.first("SELECT id FROM cueLines WHERE text = ? AND deletedAt IS NULL ORDER BY createdAt, id LIMIT 1", [text], { $0.uuid(0) })
    else { return try insertLine(text, source: .you, pinned: true).id }
    try db.run("UPDATE cueLines SET pinned = 1, modifiedAt = ? WHERE id = ? AND pinned = 0", [Date.stamp, id])
    return id
  }

  func projectID(of task: UUID?) throws -> UUID? {
    try task.flatMap { try find(Card.self, $0) }?.projectID
  }

  static let openQuestion = "author = 'cue' AND choices IS NOT NULL AND answeredAt IS NULL"

  func questionsOn(_ sessionID: String) throws -> (predicate: String, bindings: [any SQLBindable]) {
    ("taskID IN (SELECT value FROM json_each(?))", [Self.idList(try sessionPlaces(sessionID))])
  }

  /// 会话等的是你在卡上的回答，再留给你回，同一件事就既在等你、又是待回复，所以要找出它。
  public func question(waitingOn sessionID: String) throws -> CueMessage? {
    let on = try questionsOn(sessionID)
    return try select(CueMessage.self, where: "\(Self.openQuestion) AND \(on.predicate)", on.bindings, orderBy: "createdAt, rowid", limit: 1).first
  }

  /// 它只随结束写下（`endQuestions`）、随放回清掉（`reopen`），有值就是收起着，不再另看 `answeredAt`。
  static let setAside = "setAsideBy IS NOT NULL"

  /// 结束提问只在这里写。只动 `predicate` 选中的还开着的提问，返回结束了几条。必须在写事务内调用。
  func endQuestions(
    answer: String? = nil, setAsideBy: UUID? = nil, where predicate: String, _ bindings: [any SQLBindable]
  ) throws -> Int {
    let now = Date.stamp
    let values: [any SQLBindable] = [answer, setAsideBy, now, now]
    try db.run(
      "UPDATE cueMessages SET answer = ?, setAsideBy = ?, answeredAt = ?, modifiedAt = ? WHERE \(Self.openQuestion) AND \(predicate)",
      values + bindings)
    return db.changes
  }

  /// 在会话里收起的不算：那是你在那边答了，Cue 不经手。
  static let setAsideOnCuePage = "\(setAside) AND setAsideBy IN (SELECT id FROM cueMessages WHERE author = 'you')"

  public func cueQuestionsSetAside() throws -> [CueMessage] {
    try select(CueMessage.self, where: Self.setAsideOnCuePage, orderBy: "createdAt, rowid")
  }

  /// 只有你在 Cue 页开口收起的放得回，别的抛 `questionEnded`。
  public func restoreCueQuestion(_ id: UUID) throws {
    try write {
      try reopen(where: "id = ? AND \(Self.setAsideOnCuePage)", [id])
      guard db.changes > 0 else { throw CueStoreError.questionEnded }
    }
  }

  func reopen(where predicate: String, _ bindings: [any SQLBindable]) throws {
    try db.run(
      "UPDATE cueMessages SET answeredAt = NULL, setAsideBy = NULL, modifiedAt = ? WHERE \(Self.setAside) AND \(predicate)", [Date.stamp] + bindings)
  }

  /// 不看关联任务的状态：要问的几类（`CueAsk`）本来就在任务做完之后问（推送、合并、发布），按任务完成算过期会让刚问的那条立刻消失；
  /// 情况变了由 Cue 撤回。
  public func cueMessagesWaitingForYou() throws -> [CueMessage] {
    try select(CueMessage.self, where: Self.openQuestion, orderBy: "createdAt, rowid")
  }

  /// 问的那句掉出了读的范围，你的回答还在读到的这段时间里。范围按 id 排除，不按时刻切：同一毫秒写下的几条，`cueMessages` 按 rowid 截，按时刻切会两边都漏掉。
  public func cueQuestionsAnswered(outside recent: [CueMessage]) throws -> [CueMessage] {
    guard let oldest = recent.first else { return [] }
    return try select(
      CueMessage.self, where: "\(Self.answered) AND answeredAt >= ?1 AND createdAt <= ?1 AND id NOT IN (SELECT value FROM json_each(?2))",
      [oldest.createdAt, Self.idList(recent.map(\.id))], orderBy: "createdAt, rowid")
  }

  /// 问过你要不要记成重点的做法（答了、收起、撤回的都算），从新到旧：同一条不问第二遍。
  public func cueHabitQuestions() throws -> [CueMessage] {
    try select(CueMessage.self, where: "ask = ?", [CueAsk.habit.rawValue], orderBy: "createdAt DESC, rowid DESC")
  }

  /// 走部分索引（`Schema.answeredIndex`），写法不一样就用不上。
  static let answered = "choices IS NOT NULL AND answer IS NOT NULL"
}
