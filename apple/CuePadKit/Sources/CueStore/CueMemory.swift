import Foundation

/// `you` 是他的原话（他在 CuePad 里记的、提问卡上选“以后……不用问”记下的、Cue 照他的原话记的），`cue` 是 Cue 自己记的。
public enum CueLineSource: String, Sendable, CaseIterable {
  case you, cue
}

/// Cue 的一条记忆。UUID 是身份；按 (`createdAt`, `id`) 排列只用于视图分块（含忘掉的）。
/// 只有 `pinned`、定时（`remindAt`、`repeats`）、`deletedAt` 会变；忘掉是软删，UUID 不变；追加与迟到同步都可能改变排序位置。
/// 到点后值班的 Cue 把重复的推到下一次、一次性的忘掉（`CueStore.fireCueSchedules`，不留成普通记忆）；不再定时也是忘掉这一条，任务完成、归档、进回收站时连带（`endCueSchedules`），恢复不复活。
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

  /// 重点（每个班次都在系统提示里）合计多少字节（各条正文的 UTF-8）的上限：过了系统提示里叫 Cue 自己合并（`CueMemoryView.pinnedText`）；
  /// 记忆页的用量按它画。重点只归 Cue 整理（他说的规矩，并错了他看得见、能纠正），后台做梦不碰。
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

/// 记忆的版本读数：行数与各行改动时刻之和。任一行变了它就变——记、忘、钉、提醒，本机写的或别的设备同步来的，迟到的也算：
/// 那一行的改动时刻变了和就变（只看最晚那一刻会漏掉改动时刻早于它的同步）。管理器的对账与后台整理都订阅它，不必每次读整份记忆；
/// 摘要不在内：写摘要不叫醒它们。
public struct CueMemoryVersion: Equatable, Sendable {
  var lines: Int
  var stamps: Int64
}

extension CueMemoryLine: Record {
  static let table = Table.cueLines
  static let columns = ["id", "text", "pinned", "source", "remindAt", "createdAt", "modifiedAt", "deletedAt", "repeats", "taskID"]
  var bindings: [any SQLBindable] { [id, text, pinned, source.rawValue, remindAt, createdAt, modifiedAt, deletedAt, repeats?.rule, task] }
  init(row: Row) {
    self.init(
      id: row.uuid(0), text: row.text(1), pinned: row.bool(2), source: Open(rawValue: row.text(3)), remindAt: row.dateOrNil(4),
      repeats: row.textOrNil(8).flatMap { CueRepeat(rule: $0) }, task: row.uuidOrNil(9),
      createdAt: row.date(5), modifiedAt: row.date(6), deletedAt: row.dateOrNil(7))
  }
}

/// 记忆里对齐的 2 的幂区间 [lo, hi) 的一行摘要（本机缓存，不同步）。底层行或生成时读取的子摘要依赖变化就作废；
/// `CueStore.cueMemory` 从小块到大块验证，读出时只保留有效摘要。
public struct CueMemorySummary: Equatable, Sendable {
  public var lo: Int
  public var hi: Int
  public var text: String
  public var createdAt: Date
}

/// 记忆里最近记下的几条（没忘掉、不是定时的，新的在前）与一共几条：手机 Cue 面板与记忆页只读它，不读整份记忆与摘要（那是 Cue 的视图要的）。
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
