import CueText
import Foundation

extension CueStore {
  @discardableResult
  public func addCueMessage(
    _ author: CueAuthor, text: String, shots: [CueShot] = [], urgent: Bool = false, task: UUID? = nil, answeredRequests: [UUID]? = [], id: UUID = UUID()
  ) throws -> CueMessage {
    try write {
      try putCueMessage(author, text: text, shots: shots, urgent: urgent, task: task, answeredRequests: answeredRequests, id: id)
    }
  }

  func putCueMessage(
    _ author: CueAuthor, text: String, shots: [CueShot] = [], urgent: Bool = false,
    task: UUID? = nil, answeredRequests: [UUID]? = [], id: UUID = UUID()
  ) throws -> CueMessage {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CueStoreError.blankDeliveryContent }
    try checkShots(shots)
    return try insertCueMessage(author, text: text, shots: shots, urgent: urgent, task: task, answeredRequests: answeredRequests, id: id)
  }

  @discardableResult
  public func addCueMessage(_ author: CueAuthor, shown: ShownText, urgent: Bool = false) throws -> CueMessage {
    try write { try insertCueMessage(author, shown: shown, urgent: urgent) }
  }

  func checkShots(_ shots: [CueShot]) throws {
    for shot in shots where try find(PreviewItem.self, shot.preview) == nil { throw CueStoreError.shotMissing(shot.preview.uuidString.lowercased()) }
  }

  func insertCueMessage(
    _ author: CueAuthor, text: String = "", shown: ShownText? = nil, shots: [CueShot] = [],
    urgent: Bool = false, task: UUID? = nil, tools: ChatMessage.Tools? = nil, wake: CueWake? = nil, at time: Date? = nil, answeredRequests: [UUID]? = [], id: UUID = UUID()
  ) throws -> CueMessage {
    let now = Date.stamp
    var message = CueMessage(
      id: id, author: .known(author), text: shown?.text ?? text, shownText: shown, shots: shots, urgent: urgent, taskID: task,
      deliveredAt: nil, createdAt: time ?? now, modifiedAt: now, tools: tools, answeredRequests: author == .cue ? answeredRequests : nil, wake: wake,
      places: try CuePlace.capture(task: task, wake: wake, in: db), notify: nil)
    if author == .cue { message.notify = try message.alerts && reaches(.cue) ? .alert : .wake }
    try insert(message)
    try registerAttachments(in: text)
    return message
  }

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

  public func replyCueRound(startedAt: Date, reply: ShownText, as author: CueAuthor, answersYou: Bool, answeredRequests: [UUID] = []) throws {
    try write { _ = try putCueReply(startedAt: startedAt, reply: "", shown: reply, as: author, answersYou: answersYou, answeredRequests: answeredRequests) }
  }

  private func putCueReply(startedAt: Date, reply: String, shown: ShownText? = nil, as author: CueAuthor, answersYou: Bool, answeredRequests: [UUID]? = []) throws -> UUID? {
    guard !(shown?.text ?? reply).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let said = try select(CueMessage.self, where: "author = 'cue' AND createdAt >= ?", [startedAt])
    guard answersYou || said.isEmpty else { return nil }
    return try insertCueMessage(author, text: reply, shown: shown, urgent: answersYou && !said.contains(where: \.alerts), answeredRequests: answeredRequests).id
  }

  static let toDeliver = "author = 'you' AND deliveredAt IS NULL"

  public func cueMessagesToDeliver() throws -> [CueMessage] {
    try select(CueMessage.self, where: Self.toDeliver, orderBy: "createdAt, rowid")
  }

  public func markCueMessagesDelivered(_ ids: [UUID], at time: Date = .now) throws {
    guard !ids.isEmpty else { return }
    try write {
      try db.run(
        "UPDATE cueMessages SET deliveredAt = ?1, modifiedAt = ?2 WHERE id IN (SELECT value FROM json_each(?3)) AND \(Self.toDeliver)",
        [time, Date.stamp, Self.idList(ids)])
    }
  }

  public func withdrawCueMessage(_ id: UUID) throws -> Bool {
    try write {
      try db.run("DELETE FROM cueMessages WHERE id = ? AND author = 'you' AND deliveredAt IS NULL", [id])
      return db.changes > 0
    }
  }

  public func cueMessagesUnanswered() throws -> [UUID] {
    try db.query(
      """
      WITH answered AS (
        SELECT lower(j.value) AS id, max(r.modifiedAt) AS at FROM cueMessages r, json_each(r.answeredRequests) j
        WHERE r.author = 'cue' AND r.answeredRequests IS NOT NULL GROUP BY lower(j.value))
      SELECT m.id FROM cueMessages m LEFT JOIN answered a ON a.id = m.id
      WHERE m.deliveredAt IS NOT NULL AND (a.at IS NULL OR a.at < m.deliveredAt)
        AND m.author = 'you'
        AND NOT EXISTS (SELECT 1 FROM cueMessages r WHERE r.author = 'cue' AND r.answeredRequests IS NULL AND r.createdAt >= m.deliveredAt)
      """
    ) { $0.uuid(0) }
  }

  public func cueSaidInHand() throws -> [String] {
    try select(CueMessage.self, where: "id IN (SELECT value FROM json_each(?))", [Self.idList(try cueMessagesUnanswered())], orderBy: "createdAt, rowid")
      .map(\.text)
  }

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

  public func cueUnread() throws -> [UUID] {
    try db.query(
      """
      SELECT id FROM cueMessages
      WHERE author = 'cue'
        AND createdAt > MAX(
          IFNULL((SELECT modifiedAt FROM marks WHERE id = ?1), 0),
          IFNULL((SELECT createdAt FROM cueMessages WHERE author = 'you' ORDER BY createdAt DESC LIMIT 1), 0))
      ORDER BY createdAt, rowid
      """, [Mark.cueRead.id]
    ) { $0.uuid(0) }
  }
}
