import Foundation

public enum CueLineSource: String, Sendable, CaseIterable {
  case you, cue
}

/// Cue 的一条记忆。只追加，位置就是身份：按 (`createdAt`, `id`) 排的序号（含忘掉的）。
/// 只有 `pinned`、`remindAt`、`deletedAt` 会变；忘掉是软删，位置不变。
public struct CueMemoryLine: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var text: String
  /// 一直记着：记忆视图里总是全文列出。
  public var pinned: Bool
  public var source: Open<CueLineSource>
  /// 到点叫醒 Cue。
  public var remindAt: Date?
  public var createdAt: Date
  public var modifiedAt: Date
  public var deletedAt: Date?

  /// 一条最多这么多字节（UTF-8），超了拒绝。
  public static let maxBytes = 280

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
  static let columns = ["id", "text", "pinned", "source", "remindAt", "createdAt", "modifiedAt", "deletedAt"]
  var bindings: [any SQLBindable] { [id, text, pinned, source.rawValue, remindAt, createdAt, modifiedAt, deletedAt] }
  init(row: Row) {
    self.init(
      id: row.uuid(0), text: row.text(1), pinned: row.bool(2), source: Open(rawValue: row.text(3)), remindAt: row.dateOrNil(4),
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

/// 最近记下的几条（没忘掉的，新的在前）与没忘掉的一共几条：手机 Cue 面板"刚记下"那一块只读它，不读整份记忆。
public struct CueMemoryRecent: Equatable, Sendable {
  public var lines: [CueMemoryLine]
  public var count: Int
}

/// 记忆的全貌：全部行（序号即下标，含忘掉的）与仍然有效的摘要，一次读出。记忆视图（`CueAgent`）从它算。
public struct CueMemory: Equatable, Sendable {
  public var lines: [CueMemoryLine]
  public var summaries: [CueMemorySummary]
}
