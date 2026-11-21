import Foundation

public enum CueLineSource: String, Sendable, CaseIterable {
  case you, cue
}

public struct CueMemoryLine: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var text: String
  public var pinned: Bool
  public var source: Open<CueLineSource>
  public var remindAt: Date?
  public var repeats: CueRepeat?
  public var task: UUID?
  public var createdAt: Date
  public var modifiedAt: Date
  public var deletedAt: Date?

  public static let maxBytes = 280

  public static let pinnedHard = 8192

  public static func bytes(_ lines: some Sequence<CueMemoryLine>) -> Int { lines.reduce(0) { $0 + $1.text.utf8.count } }

  public static func fits(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed.utf8.count <= maxBytes
  }

  static func fitting(_ part: String, in frame: (String) -> String) -> String {
    let whole = frame(part)
    guard whole.utf8.count > maxBytes else { return whole }
    let ellipsis = "…"
    let room = maxBytes - frame(ellipsis).utf8.count
    var kept = ""
    for character in part {
      guard kept.utf8.count + character.utf8.count <= room else { break }
      kept.append(character)
    }
    return frame(kept + ellipsis)
  }
}

public struct CueMemoryVersion: Equatable, Sendable {
  var lines: Int
  var stamps: Int64
}

extension CueMemoryLine: Record, SyncedColumns {
  static let table = Table.cueLines
  static let fields: [Field] = [
    .plain("id"), .encrypted("text"), .plain("pinned"), .plain("source"), .plain("remindAt"), .plain("createdAt"),
    .plain("modifiedAt"), .plain("deletedAt"), .plain("repeats"), .plain("taskID"),
  ]
  var bindings: [any SQLBindable] { [id, text, pinned, source.rawValue, remindAt, createdAt, modifiedAt, deletedAt, repeats?.rule, task] }
  init(row: Row) {
    self.init(
      id: row.uuid(0), text: row.text(1), pinned: row.bool(2), source: Open(rawValue: row.text(3)), remindAt: row.dateOrNil(4),
      repeats: row.textOrNil(8).flatMap { CueRepeat(rule: $0) }, task: row.uuidOrNil(9),
      createdAt: row.date(5), modifiedAt: row.date(6), deletedAt: row.dateOrNil(7))
  }
}

public struct CueMemorySummary: Equatable, Sendable {
  public var lo: Int
  public var hi: Int
  public var text: String
  public var createdAt: Date
}

public struct CueMemoryRecent: Equatable, Sendable {
  public var lines: [CueMemoryLine]
  public var count: Int
}

public struct CueScheduled: Identifiable, Equatable, Sendable {
  public var line: CueMemoryLine
  public var last: Last?

  public var id: UUID { line.id }

  public struct Last: Equatable, Sendable {
    public var due: Date
    public var at: Date

    public init(due: Date, at: Date) {
      self.due = due
      self.at = at
    }

    public var late: Bool { CueFire.late(due, at: at) }
  }
}

public struct CueMemory: Equatable, Sendable {
  public var lines: [CueMemoryLine]
  public var summaries: [CueMemorySummary]
}
