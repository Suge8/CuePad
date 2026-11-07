import CueText
import Foundation

extension CueStore {
  static let lineOrder = "createdAt, id"
  /// 定时与记忆同表，只分这一处：有下一次、没忘掉的是定时（`CueMemoryLine`），其余没忘掉的是记忆
  private static let scheduled = "remindAt IS NOT NULL AND deletedAt IS NULL"
  private static let kept = "remindAt IS NULL AND deletedAt IS NULL"

  /// 记一条（带 `remindAt` 是一条定时，见 `CueMemoryLine`）。记不成一条的（`CueMemoryLine.fits`：空白、超过 `CueMemoryLine.maxBytes` 字节）拒绝。
  /// `replacing` 是这一条取代的几条（改了说法、几条并成一条）：同一次写入里忘掉它们，要都还在、都不是定时，否则整件不写（`notFound`）。
  /// 返回这一条；UUID 是跨设备稳定身份。
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

  public func cueLine(_ id: UUID) throws -> CueMemoryLine? { try find(CueMemoryLine.self, id) }

  /// 按给定 UUID 的先后读出记忆；不在了的跳过。
  public func cueLines(_ ids: [UUID]) throws -> [CueMemoryLine] {
    let found = try select(CueMemoryLine.self, where: "id IN (SELECT value FROM json_each(?))", [Self.idList(ids)])
    return ids.compactMap { id in found.first { $0.id == id } }
  }

  /// 忘掉一条（软删，身份不变）；覆盖它的摘要随之作废（摘要的指纹含各行忘没忘，见 `cueMemory`）。已忘掉的不变。
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

  /// 全部记忆与有效的摘要，一次读出。摘要生成时区间里各行的身份与内容记成指纹，现在对不上（别处同步来更早的行、
  /// 本机或别的设备忘掉、钉上或取消了其中一行，哪怕同步晚到），或实际读取的子摘要变了就作废。摘要不含重点，钉上后旧摘要不能再带着它。
  public func cueMemory() throws -> CueMemory {
    let lines = try select(CueMemoryLine.self, orderBy: Self.lineOrder)
    let summaries = try db.query("SELECT lo, hi, text, lineIDs, createdAt FROM cueSummaries ORDER BY lo, hi") { row in
      (summary: CueMemorySummary(lo: Int(row.int(0)), hi: Int(row.int(1)), text: row.text(2), createdAt: row.date(4)), ids: row.text(3))
    }
    var memory = CueMemory(lines: lines, summaries: [])
    // 子块先验证；父块只能引用已经验证的子摘要，失效沿实际输入依赖向上传播。
    for entry in summaries.sorted(by: { $0.summary.hi - $0.summary.lo < $1.summary.hi - $1.summary.lo }) {
      if memory.range(lo: entry.summary.lo, hi: entry.summary.hi)?.fingerprint == entry.ids {
        memory.summaries.append(entry.summary)
      }
    }
    return memory
  }

  /// 记忆（没忘掉、不是定时的）里最新的 `limit` 条（不给是全部）与一共几条（`CueMemoryRecent`）：手机面板读两条，记忆页读全部。
  public func recentCueMemory(limit: Int = -1) throws -> CueMemoryRecent {
    let lines = try select(CueMemoryLine.self, where: Self.kept, orderBy: "createdAt DESC, id DESC", limit: limit)
    let count = try db.first("SELECT count(*) FROM cueLines WHERE \(Self.kept)") { Int($0.int(0)) } ?? 0
    return CueMemoryRecent(lines: lines, count: count)
  }

  /// 记忆的版本读数（`CueMemoryVersion`）：一条聚合，不读行的内容。
  public func cueMemoryVersion() throws -> CueMemoryVersion {
    try db.first("SELECT count(*), coalesce(sum(modifiedAt), 0) FROM cueLines") { CueMemoryVersion(lines: Int($0.int(0)), stamps: $0.int(1)) }
      ?? CueMemoryVersion(lines: 0, stamps: 0)
  }
}
