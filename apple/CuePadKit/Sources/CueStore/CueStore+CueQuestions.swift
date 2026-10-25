import CueText
import Foundation

extension CueStore {
  /// 结束一条还开着的提问（`CueQuestionEnd`）；已经结束的抛 `questionEnded`，回答不是它的选项之一抛 `notAChoice`。回答交给 Cue（`toDeliver`），撤回的不交。
  /// 你选的是第二项（"以后……不用问"，`CueAsk.always(in:)`）时，同一个事务里把这句原话记成一条你说的、一直记着的记忆：
  /// 不用先问的例外只在记忆里，Cue 读到就直接做。返回记下的那一条的 id（调用方连同提问一起上传）。
  @discardableResult
  public func endCueQuestion(_ id: UUID, _ end: CueQuestionEnd) throws -> UUID? {
    try write {
      guard let message = try find(CueMessage.self, id) else { throw CueStoreError.notFound }
      if case .answered(let answer) = end, message.choices?.contains(answer) != true { throw CueStoreError.notAChoice(answer) }
      let answer: String? = if case .answered(let text) = end { text } else { nil }
      guard try endQuestions(answer: answer, where: "id = ?", [id]) > 0 else { throw CueStoreError.questionEnded }
      guard let answer, message.allowsFromNowOn(answer) else { return nil }
      return try insertLine(answer, source: .you, pinned: true).id
    }
  }

  /// 任务所在的项目；没有任务为 nil。
  func projectID(of task: UUID?) throws -> UUID? {
    try task.flatMap { try find(Card.self, $0) }?.projectID
  }

  /// 还开着的提问（唯一定义）：Cue 带选项问的、还没结束。
  static let openQuestion = "author = 'cue' AND choices IS NOT NULL AND answeredAt IS NULL"

  /// 你开口收起的提问（唯一定义，也是它的部分索引的条件）：记着是哪句话收起的（`CueMessage.setAsideBy`）。
  /// 它只随结束写下（`endQuestions`）、随放回清掉（`reopen`），有值就是收起着，不再另看 `answeredAt`。
  static let setAside = "setAsideBy IS NOT NULL"

  /// 结束提问只在这里写：结束的时刻，与你的回答或收起它的那句话（撤回的都没有）。只动 `predicate` 选中的还开着的提问，返回结束了几条。
  /// 必须在写事务内调用。
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

  /// 收起的提问放回"等你"（必须在写事务内调用）。
  func reopen(where predicate: String, _ bindings: [any SQLBindable]) throws {
    try db.run(
      "UPDATE cueMessages SET answeredAt = NULL, setAsideBy = NULL, modifiedAt = ? WHERE \(Self.setAside) AND \(predicate)", [Date.stamp] + bindings)
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

  /// 你答了的提问（撤回的 answer 为空）：也是它的部分索引（`Schema.answeredIndex`）的条件，不一样就用不上。
  static let answered = "choices IS NOT NULL AND answer IS NOT NULL"
}
