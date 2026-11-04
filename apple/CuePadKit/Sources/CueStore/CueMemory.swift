import Foundation

/// 一条记忆是谁的话：`you` 是他的原话（他在 CuePad 里记的、提问卡上选"以后……不用问"记下的、Cue 照他的原话记的），`cue` 是 Cue 自己记的。
/// 界面写"你说的"，Cue 在记忆里看到的写作 [他]（`CueMemoryLine.shown`）。
public enum CueLineSource: String, Sendable, CaseIterable {
  case you, cue
}

/// Cue 的一条记忆。只追加，位置就是身份：按 (`createdAt`, `id`) 排的序号（含忘掉的）。
/// 只有 `pinned`、定时（`remindAt`、`repeats`）、`deletedAt` 会变；忘掉是软删，位置不变。
/// 定时就是有 `remindAt` 的那几条：`remindAt` 是下一次，`repeats` 是怎么重复（一次性的没有），`task` 是挂在哪件任务上（到点 Cue 开工它）。
/// 到点后值班的 Cue 把重复的推到下一次、一次性的忘掉（`CueStore.fireCueSchedules`，不留成普通记忆）；不再定时也是忘掉这一条，任务完成、归档、进回收站时连带（`endCueSchedules`），恢复不复活。
public struct CueMemoryLine: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var text: String
  /// 一直记着：记忆视图里总是全文列出。
  public var pinned: Bool
  public var source: Open<CueLineSource>
  /// 定时的下一次：到点叫醒 Cue
  public var remindAt: Date?
  public var repeats: CueRepeat?
  /// 定时挂在哪件任务上
  public var task: UUID?
  public var createdAt: Date
  public var modifiedAt: Date
  public var deletedAt: Date?

  /// 一条最多这么多字节（UTF-8），超了拒绝。
  public static let maxBytes = 280

  /// 一直记着的（每个班次都在系统提示里）合计多少字节（各条正文的 UTF-8）的两条线：过了 `pinnedSoft` 后台整理（做梦）把它们收口，
  /// 过了 `pinnedHard` 系统提示里叫 Cue 自己合并（`CueMemoryView.pinnedText`）；记忆页的用量也按这两条画。
  public static let pinnedSoft = 4096
  public static let pinnedHard = 8192

  /// 这几条正文合计的字节数（一直记着的用量，同上两条线的口径）。
  public static func bytes(_ lines: some Sequence<CueMemoryLine>) -> Int { lines.reduce(0) { $0 + $1.text.utf8.count } }

  /// 这段话能记成一条（去掉首尾空白后不空、不超过 `maxBytes` 字节）：界面输入时与写入时同一个判断。
  public static func fits(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed.utf8.count <= maxBytes
  }

  /// `frame` 套上 `part` 写成的一条（提问卡第二项套项目名）；超过 `maxBytes` 时从尾部截短 `part`、补"…"，截到放得下为止。
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

/// 记忆的版本读数：行数与最后改动（记、忘、钉、提醒），任一变了它就变。管理器订阅它，不必每次读整份记忆；摘要不在内：管理器不看摘要。
public struct CueMemoryVersion: Equatable, Sendable {
  var lines: Int
  var modifiedAt: Date?
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

/// 记忆里对齐的 2 的幂区间 [lo, hi) 的一行摘要（本机缓存，不同步）。区间里有行在摘要写下之后被忘掉（含同步晚到的）、或行序变了
/// （别处同步来更早的行），它就作废：读出时已滤掉（`CueStore.cueMemory`）。
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

/// 一条定时与它上一次到点（读那一轮的叫醒原因，`CueWake.schedule`）：任务气泡与定时页都读它。
public struct CueScheduled: Identifiable, Equatable, Sendable {
  public var line: CueMemoryLine
  /// 上一次到点：本该几点（`CueFire.due`）、几点叫醒的 Cue（那一轮开始的时刻）
  public var last: Last?

  public var id: UUID { line.id }

  public struct Last: Equatable, Sendable {
    public var due: Date
    public var at: Date

    public init(due: Date, at: Date) {
      self.due = due
      self.at = at
    }

    /// 错过了、之后才补上（`CueFire.late`）
    public var late: Bool { CueFire.late(due, at: at) }
  }
}

/// 记忆的全貌：全部行（序号即下标，含忘掉的）与仍然有效的摘要，一次读出。记忆视图（`CueAgent`）从它算。
public struct CueMemory: Equatable, Sendable {
  public var lines: [CueMemoryLine]
  public var summaries: [CueMemorySummary]
}
