import CryptoKit
import CueText
import Foundation

// MARK: 对话

extension CueStore {
  /// 写一条对话。正文不能为空；选项去掉空白的，一个都不剩时当没有。
  @discardableResult
  public func addCueMessage(
    _ author: CueAuthor, text: String, choices: [String]? = nil, urgent: Bool = false, task: UUID? = nil
  ) throws -> CueMessage {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CueStoreError.blankDeliveryContent }
    let options = choices?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    return try write {
      let now = Date.stamp
      let message = CueMessage(
        id: UUID(), author: .known(author), text: text, choices: options?.isEmpty == false ? options : nil, urgent: urgent, taskID: task,
        answer: nil, answeredAt: nil, deliveredAt: nil, createdAt: now, modifiedAt: now, notify: false)
      try insert(message)
      try registerImages(in: text)
      return message
    }
  }

  /// 回答 Cue 的一条消息（"等你"的那种）。已答过的改成新的回答。
  public func answerCueMessage(_ id: UUID, answer: String) throws {
    try write {
      let now = Date.stamp
      try db.run("UPDATE cueMessages SET answer = ?, answeredAt = ?, modifiedAt = ? WHERE id = ?", [answer, now, now, id])
      guard db.changes > 0 else { throw CueStoreError.notFound }
    }
  }

  /// 这些你的消息、"等你"上的回答已交给 Cue 的大脑（Cue 住的那台 Mac 写）。已记过的不改，回答在那之后改过的再记一次。
  public func markCueMessagesDelivered(_ ids: [UUID], at time: Date = .now) throws {
    guard !ids.isEmpty else { return }
    try write {
      try db.run(
        """
        UPDATE cueMessages SET deliveredAt = ?1, modifiedAt = ?2 WHERE id IN (SELECT value FROM json_each(?3))
          AND (deliveredAt IS NULL OR (answeredAt IS NOT NULL AND answeredAt > deliveredAt))
        """, [time, Date.stamp, Self.idList(ids)])
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

  /// 要推到手机：置推送标志（值班的 Mac 按通知规则调用；见 `CueMessage.notify`）。
  public func flagCueMessageForPush(_ id: UUID) throws {
    try write {
      try db.run(
        "UPDATE cueMessages SET notify = ?1, modifiedAt = ?2 WHERE id = ?3 AND notify IS NULL", [CueMessage.notifyFlag, Date.stamp, id])
    }
  }

  /// 最近的 `limit` 条对话，从早到晚。
  public func cueMessages(limit: Int = 200) throws -> [CueMessage] {
    try select(CueMessage.self, orderBy: "createdAt DESC, rowid DESC", limit: limit).reversed()
  }

  /// 你说了、还没交给 Cue 的大脑的消息，从早到晚。
  public func undeliveredCueMessages() throws -> [CueMessage] {
    try select(CueMessage.self, where: "author = 'you' AND deliveredAt IS NULL", orderBy: "createdAt, rowid")
  }

  /// "等你"上你的回答还没交给 Cue 的大脑的（没交过，或交过之后改了），从早到晚。
  public func undeliveredCueAnswers() throws -> [CueMessage] {
    try select(
      CueMessage.self, where: "author = 'cue' AND answeredAt IS NOT NULL AND (deliveredAt IS NULL OR deliveredAt < answeredAt)",
      orderBy: "createdAt, rowid")
  }

  /// 在等你回答的消息（`CueMessage.isWaiting`），从早到晚。
  public func cueMessagesWaitingForYou() throws -> [CueMessage] {
    try select(CueMessage.self, where: "author = 'cue' AND choices IS NOT NULL AND answeredAt IS NULL", orderBy: "createdAt, rowid")
  }
}

// MARK: 记忆

extension CueStore {
  private static let lineOrder = "createdAt, id"

  /// 记一条。超过 `CueMemoryLine.maxBytes` 字节或空白的拒绝。返回这一条与它的序号。
  @discardableResult
  public func noteCueLine(
    _ text: String, source: CueLineSource, pinned: Bool = false, remindAt: Date? = nil
  ) throws -> (line: CueMemoryLine, index: Int) {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw CueStoreError.blankTaskContent }
    guard text.utf8.count <= CueMemoryLine.maxBytes else { throw CueStoreError.memoryLineTooLong(CueMemoryLine.maxBytes) }
    return try write {
      let now = Date.stamp
      let line = CueMemoryLine(
        id: UUID(), text: text, pinned: pinned, source: .known(source), remindAt: remindAt, createdAt: now,
        modifiedAt: now, deletedAt: nil)
      try insert(line)
      return (line, try index(of: line))
    }
  }

  /// 第 `index` 条（按序号，含忘掉的）；没有为 nil。
  public func cueLine(at index: Int) throws -> CueMemoryLine? {
    guard index >= 0 else { return nil }
    return try select(CueMemoryLine.self, orderBy: Self.lineOrder, limit: 1, offset: index).first
  }

  public func cueLine(_ id: UUID) throws -> CueMemoryLine? { try find(CueMemoryLine.self, id) }

  /// 一条的序号。
  public func cueLineIndex(_ id: UUID) throws -> Int? {
    try find(CueMemoryLine.self, id).map(index(of:))
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

  /// 一直记着，或取消。
  public func pinCueLine(_ id: UUID, _ pinned: Bool) throws {
    try write {
      try db.run("UPDATE cueLines SET pinned = ?, modifiedAt = ? WHERE id = ? AND pinned != ?", [pinned, Date.stamp, id, pinned])
      guard try find(CueMemoryLine.self, id) != nil else { throw CueStoreError.notFound }
    }
  }

  /// 提醒叫醒过了：清掉它的时刻。
  public func clearCueReminder(_ id: UUID) throws {
    try write { try db.run("UPDATE cueLines SET remindAt = NULL, modifiedAt = ? WHERE id = ? AND remindAt IS NOT NULL", [Date.stamp, id]) }
  }

  /// 到点了的提醒（`remindAt` 不晚于 `now`、没忘掉），最早的在前。
  public func dueCueReminders(at now: Date = .now) throws -> [CueMemoryLine] {
    try select(CueMemoryLine.self, where: "remindAt IS NOT NULL AND remindAt <= ? AND deletedAt IS NULL", [now], orderBy: "remindAt, id")
  }

  /// 下一个还没到点的提醒时刻；没有为 nil。管理器据此排下一次叫醒。
  public func nextCueReminder(after now: Date = .now) throws -> Date? {
    try db.first("SELECT MIN(remindAt) FROM cueLines WHERE remindAt > ? AND deletedAt IS NULL", [now]) { $0.dateOrNil(0) } ?? nil
  }

  /// 全部记忆与有效的摘要，一次读出。摘要写下时区间里各行的 id 与忘没忘记成指纹，现在对不上（别处同步来更早的行、
  /// 本机或别的设备忘掉了其中一行，哪怕忘掉的时刻早于摘要、同步晚到）就作废。
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

  /// 写区间 [lo, hi) 的摘要（覆盖旧的）：对齐的 2 的幂区间（至少两行），行要都在；摘要同一条记忆的长度上限。
  public func setCueSummary(lo: Int, hi: Int, text: String) throws {
    let size = hi - lo
    guard lo >= 0, size >= 2, size & (size - 1) == 0, lo % size == 0 else { throw CueStoreError.invalidSummaryRange }
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw CueStoreError.blankTaskContent }
    guard text.utf8.count <= CueMemoryLine.maxBytes else { throw CueStoreError.memoryLineTooLong(CueMemoryLine.maxBytes) }
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
    SHA256.hash(data: Data(lines.map { $0.id.uuidString + ($0.deletedAt == nil ? "" : "-") }.joined(separator: ",").utf8)).prefix(12).hex
  }

}

// MARK: 设置

extension CueStore {
  /// Cue 的设置；从没设过为 nil。
  public func cueProfile() throws -> CueProfile? { try find(CueProfile.self, CueProfile.recordID) }

  /// 改设置（没有就从默认值建一行）；返回改后的。
  @discardableResult
  public func updateCueProfile(_ edit: @Sendable (inout CueProfile) -> Void) throws -> CueProfile {
    try write {
      var profile = try cueProfile() ?? CueProfile()
      edit(&profile)
      profile.modifiedAt = Date.stamp
      try db.run(
        """
        INSERT INTO cueProfile (\(CueProfile.columns.joined(separator: ", "))) VALUES (\(CueProfile.columns.map { _ in "?" }.joined(separator: ", ")))
        ON CONFLICT(id) DO UPDATE SET \(CueProfile.columns.dropFirst().map { "\($0) = excluded.\($0)" }.joined(separator: ", "))
        """, profile.bindings)
      return profile
    }
  }
}

// MARK: 回想

/// `CueStore.recallCue` 的结果：命中的记忆（带序号）、对话与灵感任务。
public struct CueRecall: Equatable, Sendable {
  public var lines: [CueIndexedLine]
  public var messages: [CueMessage]
  public var cards: [Card]
}

/// 一条记忆与它的序号。
public struct CueIndexedLine: Equatable, Sendable {
  public var index: Int
  public var line: CueMemoryLine

  public init(index: Int, line: CueMemoryLine) {
    self.index = index
    self.line = line
  }
}

extension CueStore {
  /// 全文找：记忆（含忘掉的，标着）、对话、灵感与任务（同 `search`）。每个词都要命中，不分大小写；每类至多 `limit` 条，最近的在前。
  public func recallCue(_ query: String, limit: Int = 20) throws -> CueRecall {
    let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !words.isEmpty else { return CueRecall(lines: [], messages: [], cards: []) }
    let like = words.map { _ in "text LIKE ? ESCAPE '\\'" }.joined(separator: " AND ")
    let patterns: [any SQLBindable] = words.map {
      "%" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
    }
    let lines = try db.query(
      """
      SELECT * FROM (SELECT \(CueMemoryLine.columns.joined(separator: ", ")), ROW_NUMBER() OVER (ORDER BY createdAt, id) - 1 FROM cueLines)
      WHERE \(like) ORDER BY createdAt DESC, id DESC LIMIT \(limit)
      """, patterns
    ) { row in CueIndexedLine(index: Int(row.int(Int32(CueMemoryLine.columns.count))), line: CueMemoryLine(row: row)) }
    let messages = try select(CueMessage.self, where: like, patterns, orderBy: "createdAt DESC, rowid DESC", limit: limit)
    let cards = try search(SearchQuery(text: query), limit: limit).cards
    return CueRecall(lines: lines, messages: messages, cards: cards)
  }
}
