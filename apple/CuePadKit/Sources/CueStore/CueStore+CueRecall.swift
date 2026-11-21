import CueText
import Foundation

public struct CueRecall: Equatable, Sendable {
  public var lines: [CueMemoryLine] = []
  public var messages: [CueMessage] = []
  public var cards: [Card] = []
  public var replies: [Reply] = []
  public var unlisted = Unlisted()

  public struct Unlisted: Equatable, Sendable {
    public var lines = 0, messages = 0, cards = 0, replies = 0
  }

  public struct Reply: Equatable, Sendable {
    public var message: ChatMessage
    public var session: SessionState?
  }
}

public struct CueSaid: Equatable, Sendable {
  public var said: [CueRecall.Reply]
  public var through: Int64
}

extension CueStore {
  static let cueSessions = """
    \(sessionsUsed(where: "1"))
    UNION SELECT targetRef FROM sendRecords WHERE origin = '\(DeliveryOrigin.cue.rawValue)' AND targetKind = '\(SendTargetKind.piSession.rawValue)'
    """

  public func recallCue(_ query: String, limit: Int = 20) throws -> CueRecall {
    let patterns = Self.recallPatterns(query)
    guard !patterns.isEmpty else { return CueRecall() }
    let text = Self.recallText
    var found = CueRecall()
    let line = try recallQuery(from: "cueLines", where: "1", hit: text, patterns, length: "length(text)", then: "createdAt DESC, id DESC")
    found.lines = try select(CueMemoryLine.self, where: line.condition, line.arguments, orderBy: line.orderBy, limit: limit)
    found.unlisted.lines = try unlisted("cueLines", line, limit)
    let message = try recallQuery(from: CueMessage.table.rawValue, where: "1", hit: text, patterns, length: "length(text)", then: "createdAt DESC, rowid DESC")
    found.messages = try select(CueMessage.self, where: message.condition, message.arguments, orderBy: message.orderBy, limit: limit)
    found.unlisted.messages = try unlisted(CueMessage.table.rawValue, message, limit)
    let cardHit = "id IN (SELECT refID FROM searchIndex WHERE kind = 'card' AND text LIKE ? ESCAPE '\\')"
    let card = try recallQuery(from: "cards", where: Self.cardVisible, hit: cardHit, patterns, length: nil, then: "modifiedAt DESC, id")
    found.cards = try select(Card.self, where: card.condition, card.arguments, orderBy: card.orderBy, limit: limit)
    found.unlisted.cards = try unlisted("cards", card, limit)
    let reply: RecallQuery
    (found.replies, reply) = try recallSessions(Self.cueReplies, patterns, limit: limit)
    found.unlisted.replies = try unlisted(ChatMessage.table.rawValue, reply, limit)
    return found
  }

  public func recallCueReplies(_ query: String, limit: Int) throws -> [CueRecall.Reply] {
    let patterns = Self.recallPatterns(query)
    return patterns.isEmpty ? [] : try recallSessions(Self.cueReplies, patterns, limit: limit).found
  }

  private static let cueReplies = "role = '\(ChatRole.pi.rawValue)' AND sessionID IN (\(cueSessions))"

  private func recallSessions(_ scope: String, _ patterns: [any SQLBindable], limit: Int) throws -> (found: [CueRecall.Reply], query: RecallQuery) {
    let reply = try recallQuery(from: ChatMessage.table.rawValue, where: scope, hit: Self.recallText, patterns, length: "length(text)", then: "at DESC, id")
    return (try replies(where: reply.condition, reply.arguments, orderBy: reply.orderBy, limit: limit), reply)
  }

  private func replies(where condition: String, _ arguments: [any SQLBindable], orderBy: String, limit: Int) throws -> [CueRecall.Reply] {
    let messages = try select(ChatMessage.self, where: condition, arguments, orderBy: orderBy, limit: limit)
    var sessions: [String: SessionState] = [:]
    for id in Set(messages.map(\.sessionID)) { sessions[id] = try sessionState(id) }
    return messages.map { CueRecall.Reply(message: $0, session: sessions[$0.sessionID]) }
  }

  static let saidByHim = """
    role = '\(ChatRole.user.rawValue)' AND (deliveryID IS NULL OR deliveryID IN (
      SELECT id FROM deliveryRequests WHERE origin IS NULL
      UNION SELECT deliveryID FROM sendRecords WHERE origin IS NULL AND deliveryID IS NOT NULL))
    """

  public func recallSaid(_ query: String, limit: Int = 20) throws -> [CueRecall.Reply] {
    let patterns = Self.recallPatterns(query)
    return patterns.isEmpty ? [] : try recallSessions(Self.saidByHim, patterns, limit: limit).found
  }

  public func sessionMessagesThrough() throws -> Int64 {
    try db.first("SELECT COALESCE(max(arrival), 0) FROM \(ChatMessage.table.rawValue)") { $0.int(0) } ?? 0
  }

  public func said(after heard: Int64, limit: Int) throws -> CueSaid {
    let said = try replies(where: "arrival > ? AND \(Self.saidByHim)", [heard], orderBy: "arrival", limit: limit)
    let through = try said.last.flatMap { last in
      try db.first("SELECT arrival FROM \(ChatMessage.table.rawValue) WHERE id = ?", [last.message.id]) { $0.int(0) }
    }
    return CueSaid(said: said, through: through ?? heard)
  }

  private static let recallText = "(text LIKE ? ESCAPE '\\')"

  private static func recallPatterns(_ query: String) -> [any SQLBindable] {
    recallWords(query).map {
      "%" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
    }
  }

  private func unlisted(_ table: String, _ query: RecallQuery, _ limit: Int) throws -> Int {
    let total = try db.first("SELECT count(*) FROM \(table) WHERE \(query.condition)", query.countArguments) { Int($0.int(0)) } ?? 0
    return max(0, total - limit)
  }

  private struct RecallQuery {
    var condition: String, orderBy: String
    var arguments: [any SQLBindable], countArguments: [any SQLBindable]
  }

  private func recallQuery(
    from table: String, where scope: String, hit: String, _ patterns: [any SQLBindable], length: String?, then: String
  ) throws -> RecallQuery {
    let sums = patterns.indices.map { "COALESCE(SUM(\(hit.replacingOccurrences(of: "?", with: "?\($0 + 1)"))), 0)" }
    let counts = try db.first("SELECT \((["count(*)"] + sums).joined(separator: ", ")) FROM \(table) WHERE \(scope)", patterns) { row in
      (0...patterns.count).map { Double(row.int(Int32($0))) }
    } ?? []
    let total = counts.first ?? 0
    let counted = zip(patterns, counts.dropFirst()).filter { $0.1 > 0 }.map { (pattern: $0.0, count: $0.1) }
    let rare = counted.filter { $0.count <= total * Self.recallCommon }
    let used = rare.isEmpty ? counted : rare
    guard !used.isEmpty else { return RecallQuery(condition: "0", orderBy: then, arguments: [], countArguments: []) }
    let hits = used.map { _ in "(\(hit))" }
    let score = zip(hits, used).map { "\($0) * \(log((total + 1) / ($1.count + 0.5)))" }.joined(separator: " + ")
    let condition = "(\(scope)) AND (\(hits.joined(separator: " OR ")))"
    let normalized = length.map { "(\(score)) / (1 + \($0) / \(Self.recallLength))" } ?? "(\(score))"
    let patterns = used.map(\.pattern)
    return RecallQuery(condition: condition, orderBy: "\(normalized) DESC, \(then)", arguments: patterns + patterns, countArguments: patterns)
  }

  static let recallCommon = 0.2
  static let recallLength = 2000.0

  public static func recallWords(_ query: String) -> [String] {
    var seen = Set<String>()
    return query.split(whereSeparator: \.isWhitespace).map(String.init).filter { seen.insert($0.lowercased()).inserted }
  }

}
