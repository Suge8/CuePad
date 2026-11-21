import CueText
import Foundation

extension CueStore {
  static let lineOrder = "createdAt, id"
  private static let scheduled = "remindAt IS NOT NULL AND deletedAt IS NULL"
  private static let kept = "remindAt IS NULL AND deletedAt IS NULL"

  @discardableResult
  public func noteCueLine(
    _ text: String, source: CueLineSource, pinned: Bool = false, remindAt: Date? = nil, repeats: CueRepeat? = nil, task: UUID? = nil,
    replacing: [UUID] = []
  ) throws -> CueMemoryLine {
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
      return line
    }
  }

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

  public func cueLine(_ id: UUID) throws -> CueMemoryLine? { try find(CueMemoryLine.self, id) }

  public func cueLines(_ ids: [UUID]) throws -> [CueMemoryLine] {
    let found = try select(CueMemoryLine.self, where: "id IN (SELECT value FROM json_each(?))", [Self.idList(ids)])
    return ids.compactMap { id in found.first { $0.id == id } }
  }

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

  public func rescheduleCueLine(_ id: UUID, at: Date, repeats: CueRepeat?) throws {
    try write {
      guard let line = try find(CueMemoryLine.self, id), line.deletedAt == nil else { throw CueStoreError.notFound }
      try db.run("UPDATE cueLines SET remindAt = ?, repeats = ?, modifiedAt = ? WHERE id = ?", [at, repeats?.rule, Date.stamp, id])
    }
  }

  public func fireCueSchedules(_ fires: [CueFire], at now: Date = .now) throws {
    try write {
      for fire in fires {
        guard let line = try find(CueMemoryLine.self, fire.line), line.deletedAt == nil, let at = line.remindAt, at <= fire.due else { continue }
        if let repeats = line.repeats {
          try db.run("UPDATE cueLines SET remindAt = ?, modifiedAt = ? WHERE id = ?", [repeats.next(after: now), Date.stamp, line.id])
        } else {
          try db.run("UPDATE cueLines SET deletedAt = ?1, modifiedAt = ?1 WHERE id = ?2", [Date.stamp, line.id])
        }
      }
    }
  }

  public func dueCueSchedules(at now: Date = .now) throws -> [CueMemoryLine] {
    try select(CueMemoryLine.self, where: "\(Self.scheduled) AND remindAt <= ?", [now], orderBy: "remindAt, id")
  }

  public func nextCueSchedule(after now: Date = .now) throws -> Date? {
    try db.first("SELECT MIN(remindAt) FROM cueLines WHERE \(Self.scheduled) AND remindAt > ?", [now]) { $0.dateOrNil(0) } ?? nil
  }

  public func cueScheduleLines(task: UUID? = nil) throws -> [CueMemoryLine] {
    try select(CueMemoryLine.self, where: "\(Self.scheduled) AND (?1 IS NULL OR taskID = ?1)", [task], orderBy: "remindAt, id")
  }

  public func cueSchedules(task: UUID? = nil) throws -> [CueScheduled] {
    let lines = try cueScheduleLines(task: task)
    let last = try lastFires(of: Set(lines.map(\.id)))
    return lines.map { CueScheduled(line: $0, last: last[$0.id]) }
  }

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

  private static let scheduleWake = #"{"schedule":%"#

  @discardableResult
  func endCueSchedules(onTasksIn tasks: String, _ argument: any SQLBindable, at now: Date) throws -> [UUID] {
    let condition = "\(Self.scheduled) AND taskID IN (\(tasks))"
    let ended = try db.query("SELECT id FROM cueLines WHERE \(condition)", [now, argument]) { $0.uuid(0) }
    try db.run("UPDATE cueLines SET deletedAt = ?1, modifiedAt = ?1 WHERE \(condition)", [now, argument])
    return ended
  }

  func restoreCueSchedules(_ lines: [UUID]) throws {
    guard !lines.isEmpty else { return }
    try db.run("UPDATE cueLines SET deletedAt = NULL, modifiedAt = ? WHERE id IN (SELECT value FROM json_each(?))", [Date.stamp, Self.idList(lines)])
  }

  public func cueMemory() throws -> CueMemory {
    let lines = try select(CueMemoryLine.self, orderBy: Self.lineOrder)
    let summaries = try db.query("SELECT lo, hi, text, lineIDs, createdAt FROM cueSummaries ORDER BY lo, hi") { row in
      (summary: CueMemorySummary(lo: Int(row.int(0)), hi: Int(row.int(1)), text: row.text(2), createdAt: row.date(4)), ids: row.text(3))
    }
    var memory = CueMemory(lines: lines, summaries: [])
    for entry in summaries.sorted(by: { $0.summary.hi - $0.summary.lo < $1.summary.hi - $1.summary.lo }) {
      if memory.range(lo: entry.summary.lo, hi: entry.summary.hi)?.fingerprint == entry.ids {
        memory.summaries.append(entry.summary)
      }
    }
    return memory
  }

  public func recentCueMemory(limit: Int = -1) throws -> CueMemoryRecent {
    let lines = try select(CueMemoryLine.self, where: Self.kept, orderBy: "createdAt DESC, id DESC", limit: limit)
    let count = try db.first("SELECT count(*) FROM cueLines WHERE \(Self.kept)") { Int($0.int(0)) } ?? 0
    return CueMemoryRecent(lines: lines, count: count)
  }

  public func cueMemoryVersion() throws -> CueMemoryVersion {
    try db.first("SELECT count(*), coalesce(sum(modifiedAt), 0) FROM cueLines") { CueMemoryVersion(lines: Int($0.int(0)), stamps: $0.int(1)) }
      ?? CueMemoryVersion(lines: 0, stamps: 0)
  }
}
