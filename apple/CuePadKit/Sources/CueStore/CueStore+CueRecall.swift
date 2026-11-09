import CueText
import Foundation

/// `CueStore.recallCue` 的结果：命中的记忆（UUID 身份）、对话、灵感任务，与 Cue 管过的会话里 Agent 的回复；每类另有多少条命中没列出（`unlisted`）。
public struct CueRecall: Equatable, Sendable {
  public var lines: [CueMemoryLine] = []
  public var messages: [CueMessage] = []
  public var cards: [Card] = []
  public var replies: [Reply] = []
  /// 每类命中却超出 `limit` 没列出的条数，顺序同上四类
  public var unlisted = Unlisted()

  public struct Unlisted: Equatable, Sendable {
    public var lines = 0, messages = 0, cards = 0, replies = 0
  }

  /// 会话里的一条回复与它所在的会话（记录已清掉的为 nil，只剩会话 id）。
  public struct Reply: Equatable, Sendable {
    public var message: PiChatMessage
    public var session: PiSessionState?
  }
}

extension CueStore {
  /// Cue 管过的会话（唯一定义）：绑过任务的（正在用的与换下来的），或 Cue 对它说过话的（发送记录是 Cue 的）。
  static let cueSessions = """
    SELECT piSessionID FROM cards WHERE piSessionID IS NOT NULL
    UNION SELECT f.value FROM cards c, json_each(c.formerSessionIDs) f
    UNION SELECT targetRef FROM sendRecords WHERE origin = '\(DeliveryOrigin.cue.rawValue)' AND targetKind = '\(SendTargetKind.piSession.rawValue)'
    """

  /// 全文找：记忆（含忘掉的，标着）、对话、灵感与任务（没删的，含归档的，同 `search` 的索引），与 Cue 管过的会话（`cueSessions`）里 Agent 的回复原话
  /// （同步来的那份对话，`PiChatMessage`）。词之间空格隔开，不分大小写，命中任一个就算；每类在库里按 `recallQuery` 的分排好，取前 `limit` 条，
  /// 并数出命中却没列出的条数。
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
    (found.replies, reply) = try recallReplies(patterns, limit: limit)
    found.unlisted.replies = try unlisted(PiChatMessage.table.rawValue, reply, limit)
    return found
  }

  /// 只找会话回复那一类（同 `recallCue` 的 replies，不数没列出的）：信封随他的短问句带上的（`CueTools.related`）只要这一类，
  /// 四类都查在真实库上一句要 80–190 毫秒，都排在资料库的队列上。
  public func recallCueReplies(_ query: String, limit: Int) throws -> [CueRecall.Reply] {
    let patterns = Self.recallPatterns(query)
    return patterns.isEmpty ? [] : try recallReplies(patterns, limit: limit).found
  }

  private func recallReplies(_ patterns: [any SQLBindable], limit: Int) throws -> (found: [CueRecall.Reply], query: RecallQuery) {
    let scope = "role = '\(PiChatRole.pi.rawValue)' AND sessionID IN (\(Self.cueSessions))"
    let reply = try recallQuery(from: PiChatMessage.table.rawValue, where: scope, hit: Self.recallText, patterns, length: "length(text)", then: "at DESC, id")
    let replies = try select(PiChatMessage.self, where: reply.condition, reply.arguments, orderBy: reply.orderBy, limit: limit)
    var sessions: [String: PiSessionState] = [:]
    for id in Set(replies.map(\.sessionID)) { sessions[id] = try sessionState(id) }
    return (replies.map { CueRecall.Reply(message: $0, session: sessions[$0.sessionID]) }, reply)
  }

  private static let recallText = "(text LIKE ? ESCAPE '\\')"

  /// 查询里的词各一个 LIKE 模式（转义 \\、%、_）。
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

  /// recall 一类的条件与排序：`from` 里满足 `scope`、命中 `hit`（一个 `?` 绑一个词的 LIKE 模式）的，按分排，同分按 `then`。
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

  /// 这一类里含它的超过这个比例，这个词就太常见、不算命中
  static let recallCommon = 0.2
  /// 长度折算：这么长的一条分数打对折
  static let recallLength = 2000.0

  /// 查询里的词：空格隔开、去重，保持先后。
  public static func recallWords(_ query: String) -> [String] {
    var seen = Set<String>()
    return query.split(whereSeparator: \.isWhitespace).map(String.init).filter { seen.insert($0.lowercased()).inserted }
  }

}
