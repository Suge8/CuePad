import CueText
import Foundation

extension CueStore {
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

  public func question(waitingOn sessionID: String) throws -> CueMessage? {
    let on = try questionsOn(sessionID)
    return try select(CueMessage.self, where: "\(Self.openQuestion) AND \(on.predicate)", on.bindings, orderBy: "createdAt, rowid", limit: 1).first
  }

  static let setAside = "setAsideBy IS NOT NULL"

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

  static let setAsideOnCuePage = "\(setAside) AND setAsideBy IN (SELECT id FROM cueMessages WHERE author = 'you')"

  public func cueQuestionsSetAside() throws -> [CueMessage] {
    try select(CueMessage.self, where: Self.setAsideOnCuePage, orderBy: "createdAt, rowid")
  }

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

  public func cueMessagesWaitingForYou() throws -> [CueMessage] {
    try select(CueMessage.self, where: Self.openQuestion, orderBy: "createdAt, rowid")
  }

  public func cueQuestionsAnswered(outside recent: [CueMessage]) throws -> [CueMessage] {
    guard let oldest = recent.first else { return [] }
    return try select(
      CueMessage.self, where: "\(Self.answered) AND answeredAt >= ?1 AND createdAt <= ?1 AND id NOT IN (SELECT value FROM json_each(?2))",
      [oldest.createdAt, Self.idList(recent.map(\.id))], orderBy: "createdAt, rowid")
  }

  public func cueHabitQuestions() throws -> [CueMessage] {
    try select(CueMessage.self, where: "ask = ?", [CueAsk.habit.rawValue], orderBy: "createdAt DESC, rowid DESC")
  }

  /// 走部分索引（`Schema.answeredIndex`），写法不一样就用不上。
  static let answered = "choices IS NOT NULL AND answer IS NOT NULL"
}
