import CryptoKit
import CueText
import Foundation

extension CueStore {
  private static let lineOrder = "createdAt, id"
  /// 定时与记忆同表，只分这一处：有下一次、没忘掉的是定时（`CueMemoryLine`），其余没忘掉的是记忆
  private static let scheduled = "remindAt IS NOT NULL AND deletedAt IS NULL"
  private static let kept = "remindAt IS NULL AND deletedAt IS NULL"

  /// 记一条（带 `remindAt` 是一条定时，见 `CueMemoryLine`）。记不成一条的（`CueMemoryLine.fits`：空白、超过 `CueMemoryLine.maxBytes` 字节）拒绝。
  /// `replacing` 是这一条取代的几条（改了说法、几条并成一条）：同一次写入里忘掉它们，要都还在、都不是定时，否则整件不写（`notFound`）。
  /// 返回这一条与它的序号。
  @discardableResult
  public func noteCueLine(
    _ text: String, source: CueLineSource, pinned: Bool = false, remindAt: Date? = nil, repeats: CueRepeat? = nil, task: UUID? = nil,
    replacing: [UUID] = []
  ) throws -> (line: CueMemoryLine, index: Int) {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw CueStoreError.blankTaskContent }
    guard CueMemoryLine.fits(text) else { throw CueStoreError.memoryLineTooLong(CueMemoryLine.maxBytes) }
    return try write {
      let now = Date.stamp
      for id in replacing {
        guard let old = try find(CueMemoryLine.self, id), old.deletedAt == nil, old.remindAt == nil else { throw CueStoreError.notFound }
        try db.run("UPDATE cueLines SET deletedAt = ?1, modifiedAt = ?1 WHERE id = ?2", [now, id])
      }
      let line = try insertLine(text, source: source, pinned: pinned, remindAt: remindAt, repeats: repeats, task: task)
      return (line, try index(of: line))
    }
  }

  /// 记一条（在写事务内调用，调用方先查过记得成）。
  func insertLine(
    _ text: String, source: CueLineSource, pinned: Bool, remindAt: Date? = nil, repeats: CueRepeat? = nil, task: UUID? = nil
  ) throws -> CueMemoryLine {
    let now = Date.stamp
    let line = CueMemoryLine(
      id: UUID(), text: text, pinned: pinned, source: .known(source), remindAt: remindAt, repeats: repeats, task: task, createdAt: now,
      modifiedAt: now, deletedAt: nil)
    try insert(line)
    return line
  }

  /// 第 `index` 条（按序号，含忘掉的）；没有为 nil。
  public func cueLine(at index: Int) throws -> CueMemoryLine? {
    guard index >= 0 else { return nil }
    return try select(CueMemoryLine.self, orderBy: Self.lineOrder, limit: 1, offset: index).first
  }

  public func cueLine(_ id: UUID) throws -> CueMemoryLine? { try find(CueMemoryLine.self, id) }

  public func cueLineIndex(_ id: UUID) throws -> Int? {
    try find(CueMemoryLine.self, id).map(index(of:))
  }

  /// 这几条记忆与它们的序号，按给的先后（定时到点叫醒的一轮：信封里列它们、Cue 页那一节写第一条）；不在了的跳过。
  public func cueLines(_ ids: [UUID]) throws -> [CueIndexedLine] {
    let found = try select(CueMemoryLine.self, where: "id IN (SELECT value FROM json_each(?))", [Self.idList(ids)])
    return try ids.compactMap { id in try found.first { $0.id == id }.map { CueIndexedLine(index: try index(of: $0), line: $0) } }
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

  public func pinCueLine(_ id: UUID, _ pinned: Bool) throws {
    try write {
      try db.run("UPDATE cueLines SET pinned = ?, modifiedAt = ? WHERE id = ? AND pinned != ?", [pinned, Date.stamp, id, pinned])
      guard try find(CueMemoryLine.self, id) != nil else { throw CueStoreError.notFound }
    }
  }

  /// 改一条定时的下一次与怎么重复（任务气泡与定时页里原地改）；忘掉了的不改。
  public func rescheduleCueLine(_ id: UUID, at: Date, repeats: CueRepeat?) throws {
    try write {
      guard let line = try find(CueMemoryLine.self, id), line.deletedAt == nil else { throw CueStoreError.notFound }
      try db.run("UPDATE cueLines SET remindAt = ?, repeats = ?, modifiedAt = ? WHERE id = ?", [at, repeats?.rule, Date.stamp, id])
    }
  }

  /// 这几条定时叫醒过 Cue 了（`lines` 是到点时读出的）：此刻还是那一次的（`remindAt` 没在别处改过）才往下走——重复的按库里此刻的规则
  /// 推到 `now` 之后的下一次（中间错过的合成这一次），一次性的忘掉（到点就做完了，不留成普通记忆）；叫醒期间别处改过、忘掉的照改过的留着。
  public func fireCueSchedules(_ lines: [CueMemoryLine], at now: Date = .now) throws {
    try write {
      for fired in lines {
        guard let line = try find(CueMemoryLine.self, fired.id), line.deletedAt == nil, line.remindAt != nil, line.remindAt == fired.remindAt else { continue }
        if let repeats = line.repeats {
          try db.run("UPDATE cueLines SET remindAt = ?, modifiedAt = ? WHERE id = ?", [repeats.next(after: now), Date.stamp, line.id])
        } else {
          try db.run("UPDATE cueLines SET deletedAt = ?1, modifiedAt = ?1 WHERE id = ?2", [Date.stamp, line.id])
        }
      }
    }
  }

  /// 到点了的定时（`remindAt` 不晚于 `now`、没忘掉），最早的在前。
  public func dueCueSchedules(at now: Date = .now) throws -> [CueMemoryLine] {
    try select(CueMemoryLine.self, where: "\(Self.scheduled) AND remindAt <= ?", [now], orderBy: "remindAt, id")
  }

  /// 下一个还没到点的定时时刻；没有为 nil。管理器据此排下一次叫醒。
  public func nextCueSchedule(after now: Date = .now) throws -> Date? {
    try db.first("SELECT MIN(remindAt) FROM cueLines WHERE \(Self.scheduled) AND remindAt > ?", [now]) { $0.dateOrNil(0) } ?? nil
  }

  /// 全部定时（`task` 给了就只要挂在它上面的），先到点的在前。信封与看板只要这些行；要上一次到点的读 `cueSchedules`。
  public func cueScheduleLines(task: UUID? = nil) throws -> [CueMemoryLine] {
    try select(CueMemoryLine.self, where: "\(Self.scheduled) AND (?1 IS NULL OR taskID = ?1)", [task], orderBy: "remindAt, id")
  }

  /// 同 `cueScheduleLines`，各带上一次到点。
  public func cueSchedules(task: UUID? = nil) throws -> [CueScheduled] {
    let lines = try cueScheduleLines(task: task)
    let last = try lastFires(of: Set(lines.map(\.id)))
    return lines.map { CueScheduled(line: $0, last: last[$0.id]) }
  }

  /// 这几条定时各自上一次叫醒 Cue 的那一轮（经过那一行的叫醒原因，`CueWake.schedule`）：只读定时叫醒的那几行、一次读完，新的在前，每条取第一次碰到的。
  private func lastFires(of lines: Set<UUID>) throws -> [UUID: CueScheduled.Last] {
    guard !lines.isEmpty else { return [:] }
    let rows = try db.query("SELECT wake, createdAt FROM cueMessages WHERE wake LIKE ? ORDER BY createdAt DESC", [Self.scheduleWake]) {
      ($0.textOrNil(0).flatMap(CueWake.init(stored:)), $0.date(1))
    }
    var last: [UUID: CueScheduled.Last] = [:]
    for (wake, at) in rows {
      guard case .schedule(let fires)? = wake else { continue }
      for fire in fires where lines.contains(fire.line) && last[fire.line] == nil { last[fire.line] = CueScheduled.Last(due: fire.due, at: at) }
      if last.count == lines.count { break }
    }
    return last
  }

  /// 定时叫醒的那一轮存下的 wake 的开头（`CueWake.schedule` 照 `JSONColumn` 编码）。
  private static let scheduleWake = #"{"schedule":%"#

  /// 挂在 `tasks`（选出任务 id 的 SQL，参数是 ?2）上的定时不再定时（在写事务内调用）：任务完成、进回收站、归档就是这件事不用再定时做了；
  /// 恢复、取回不复活（不再定时是忘掉那一条）。
  func endCueSchedules(onTasksIn tasks: String, _ argument: any SQLBindable, at now: Date) throws {
    try db.run(
      "UPDATE cueLines SET deletedAt = ?1, modifiedAt = ?1 WHERE \(Self.scheduled) AND taskID IN (\(tasks))", [now, argument])
  }

  /// 全部记忆与有效的摘要，一次读出。摘要写下时区间里各行的 id、忘没忘、钉没钉记成指纹，现在对不上（别处同步来更早的行、
  /// 本机或别的设备忘掉、钉上或取消了其中一行，哪怕同步晚到）就作废：摘要不含一直记着的（那些在系统提示里），钉上后旧摘要不能再带着它。
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

  /// 记忆（没忘掉、不是定时的）里最新的 `limit` 条（不给是全部）与一共几条（`CueMemoryRecent`）：手机面板读两条，记忆页读全部。
  public func recentCueMemory(limit: Int = -1) throws -> CueMemoryRecent {
    let lines = try select(CueMemoryLine.self, where: Self.kept, orderBy: "createdAt DESC, id DESC", limit: limit)
    let count = try db.first("SELECT count(*) FROM cueLines WHERE \(Self.kept)") { Int($0.int(0)) } ?? 0
    return CueMemoryRecent(lines: lines, count: count)
  }

  /// 记忆的版本读数（`CueMemoryVersion`）：一条聚合，不读行的内容。
  public func cueMemoryVersion() throws -> CueMemoryVersion {
    try db.first("SELECT count(*), MAX(modifiedAt) FROM cueLines") { CueMemoryVersion(lines: Int($0.int(0)), modifiedAt: $0.dateOrNil(1)) }
      ?? CueMemoryVersion(lines: 0, modifiedAt: nil)
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
    SHA256.hash(data: Data(lines.map { $0.id.uuidString + ($0.deletedAt != nil ? "-" : $0.pinned ? "+" : "") }.joined(separator: ",").utf8)).prefix(12).hex
  }
}

/// `CueStore.recallCue` 的结果：命中的记忆（带序号）、对话、灵感任务，与 Cue 管过的会话里 Agent 的回复；每类另有多少条命中没列出（`unlisted`）。
public struct CueRecall: Equatable, Sendable {
  public var lines: [CueIndexedLine] = []
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

public struct CueIndexedLine: Equatable, Sendable {
  public var index: Int
  public var line: CueMemoryLine

  public init(index: Int, line: CueMemoryLine) {
    self.index = index
    self.line = line
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
    let words = Self.recallWords(query)
    guard !words.isEmpty else { return CueRecall() }
    let patterns: [any SQLBindable] = words.map {
      "%" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
    }
    let text = "(text LIKE ? ESCAPE '\\')"
    var found = CueRecall()
    let numbered = "(SELECT \(CueMemoryLine.columns.joined(separator: ", ")), ROW_NUMBER() OVER (ORDER BY createdAt, id) - 1 AS n FROM cueLines)"
    let line = try recallQuery(from: numbered, where: "1", hit: text, patterns, length: "length(text)", then: "createdAt DESC, id DESC")
    found.lines = try db.query(
      "SELECT * FROM \(numbered) WHERE \(line.condition) ORDER BY \(line.orderBy) LIMIT \(limit)", line.arguments
    ) { row in CueIndexedLine(index: Int(row.int(Int32(CueMemoryLine.columns.count))), line: CueMemoryLine(row: row)) }
    found.unlisted.lines = try unlisted(numbered, line, limit)
    let message = try recallQuery(from: CueMessage.table.rawValue, where: "1", hit: text, patterns, length: "length(text)", then: "createdAt DESC, rowid DESC")
    found.messages = try select(CueMessage.self, where: message.condition, message.arguments, orderBy: message.orderBy, limit: limit)
    found.unlisted.messages = try unlisted(CueMessage.table.rawValue, message, limit)
    let cardHit = "id IN (SELECT refID FROM searchIndex WHERE kind = 'card' AND text LIKE ? ESCAPE '\\')"
    let card = try recallQuery(from: "cards", where: Self.cardVisible, hit: cardHit, patterns, length: nil, then: "modifiedAt DESC, id")
    found.cards = try select(Card.self, where: card.condition, card.arguments, orderBy: card.orderBy, limit: limit)
    found.unlisted.cards = try unlisted("cards", card, limit)
    let replyScope = "role = '\(PiChatRole.pi.rawValue)' AND sessionID IN (\(Self.cueSessions))"
    let reply = try recallQuery(from: PiChatMessage.table.rawValue, where: replyScope, hit: text, patterns, length: "length(text)", then: "at DESC, id")
    let replies = try select(PiChatMessage.self, where: reply.condition, reply.arguments, orderBy: reply.orderBy, limit: limit)
    found.unlisted.replies = try unlisted(PiChatMessage.table.rawValue, reply, limit)
    var sessions: [String: PiSessionState] = [:]
    for id in Set(replies.map(\.sessionID)) { sessions[id] = try sessionState(id) }
    found.replies = replies.map { CueRecall.Reply(message: $0, session: sessions[$0.sessionID]) }
    return found
  }

  /// 一类里命中却超出 `limit` 的条数。
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
    let total = try db.first("SELECT count(*) FROM \(table) WHERE \(scope)") { Double($0.int(0)) } ?? 0
    var counted: [(pattern: any SQLBindable, count: Double)] = []
    for pattern in patterns {
      let count = try db.first("SELECT count(*) FROM \(table) WHERE (\(scope)) AND \(hit)", [pattern]) { Double($0.int(0)) } ?? 0
      if count > 0 { counted.append((pattern, count)) }
    }
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
