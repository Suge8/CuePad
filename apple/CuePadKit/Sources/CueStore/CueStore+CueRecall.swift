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

/// `through` 是其中最后一句的次序：听到哪了只能是交出去的最后一句。
public struct CueSaid: Equatable, Sendable {
  public var said: [CueRecall.Reply]
  public var through: Int64
}

extension CueStore {
  static let cueSessions = """
    SELECT piSessionID FROM cards WHERE piSessionID IS NOT NULL
    UNION SELECT f.value FROM cards c, json_each(c.formerSessionIDs) f
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

  /// 只找会话回复那一类（同 `recallCue` 的 replies，不数没列出的）：信封随他的短问句带上的（`CueTools.related`）只要这一类，
  /// 四类都查在真实库上一句要 80–190 毫秒，都排在资料库的队列上。
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

  /// 他在会话里说的话：你一方的话里有正证据是他的——终端里打的（没有投送），或 CuePad 替他发的（请求或发送记录上没有来源；Cue 送的写着来源）。
  /// 不限 Cue 管过的会话：他在自己开的会话里交代的做法也是他的规矩的来处。
  static let saidByHim = """
    role = '\(ChatRole.user.rawValue)' AND (deliveryID IS NULL OR deliveryID IN (
      SELECT id FROM deliveryRequests WHERE origin IS NULL
      UNION SELECT deliveryID FROM sendRecords WHERE origin IS NULL AND deliveryID IS NOT NULL))
    """

  /// 排法同 `recallCue`：做梦查一条做法他以前说过没有。
  public func recallSaid(_ query: String, limit: Int = 20) throws -> [CueRecall.Reply] {
    let patterns = Self.recallPatterns(query)
    return patterns.isEmpty ? [] : try recallSessions(Self.saidByHim, patterns, limit: limit).found
  }

  /// 会话对话读进这台的次序（`arrival`：原地改不变，删了也不复用）到哪了：做梦订阅它，有新的话才看。
  public func sessionMessagesThrough() throws -> Int64 {
    try db.first("SELECT COALESCE(max(arrival), 0) FROM \(ChatMessage.table.rawValue)") { $0.int(0) } ?? 0
  }

  /// 读进这台的次序在 `heard` 之后他说的话，从早到晚至多 `limit` 句；没有新的 `through` 就是 `heard`。
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

  /// 分 = 命中的词各自的少见程度 ln((N + 1) / (n + 0.5)) 相加（N 是这一类的条数，n 是其中含这个词的），再除以 1 + 长度 / 2000：
  /// 少见的词定位得准，长回复靠篇幅顺带命中的不该压过短而准的那条。这一类里两成以上都含的词不算命中（"the""测试"这类定位不到东西，也不该算进没列出的条数），
  /// 词全都这么常见时才照算。比按命中词数排准：问句与多词查询里常见词凑出的命中数会把真正的那条挤下去（LongMemEval 的离线检索，证据进前三从 77% 到 88%）。
  private func recallQuery(
    from table: String, where scope: String, hit: String, _ patterns: [any SQLBindable], length: String?, then: String
  ) throws -> RecallQuery {
    // 总条数与每个词命中几条一次扫完（一个词一条 count 时，会话回复在真实库上一句要扫十来遍）
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
