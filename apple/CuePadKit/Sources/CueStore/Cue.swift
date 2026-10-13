import CueText
import Foundation

// Cue：常驻的总控 Agent。它不写代码，只经 CuePad 的任务派活、跟进、问你、记东西。这里是它的数据：
// 对话（`cueMessages`）、记忆（`cueLines` 与本机的摘要缓存 `cueSummaries`）、设置（`cueProfile`）；它跟进哪些事记在卡片上（`Card.cueFollows`）。

/// Cue 页对话里一行是谁的。
public enum CueAuthor: String, Sendable, CaseIterable {
  /// 你对 Cue 说的
  case you
  /// Cue 对你说的；带选项的是"等你"
  case cue
  /// Cue 自己醒来那一轮的动态（折叠显示）
  case note
  /// Cue 请求换新上下文时写的交接备忘
  case handoff
}

/// Cue 页的对话：Cue 对话唯一的事实源（不读运行时的会话文件）。写入后只有回答（`answer`、`answeredAt`）与送达（`deliveredAt`）会变。
public struct CueMessage: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var author: Open<CueAuthor>
  /// 正文（`CueFormat`）；你的消息可带图片引用。
  public var text: String
  /// 给你的选项；有选项的 Cue 消息就是"等你"。
  public var choices: [String]?
  /// 要推送到手机。
  public var urgent: Bool
  /// 关联的卡片。
  public var taskID: UUID?
  public var answer: String?
  public var answeredAt: Date?
  /// 你的消息被交给 Cue 的大脑的时刻（由 Cue 住的那台 Mac 写）。
  public var deliveredAt: Date?
  public var createdAt: Date
  public var modifiedAt: Date

  /// 在等你回答：Cue 带选项问的、还没答。
  public var isWaiting: Bool { author == .known(.cue) && choices != nil && answeredAt == nil }
}

extension CueMessage: Record {
  static let table = Table.cueMessages
  static let columns = [
    "id", "author", "text", "choices", "urgent", "taskID", "answer", "answeredAt", "deliveredAt", "createdAt", "modifiedAt",
  ]
  var bindings: [any SQLBindable] {
    [id, author.rawValue, text, choices.map { JSONColumn.encode($0) }, urgent, taskID, answer, answeredAt, deliveredAt, createdAt, modifiedAt]
  }
  init(row: Row) {
    self.init(
      id: row.uuid(0), author: Open(rawValue: row.text(1)), text: row.text(2),
      choices: JSONColumn.decode([String].self, from: row.textOrNil(3)), urgent: row.bool(4), taskID: row.uuidOrNil(5),
      answer: row.textOrNil(6), answeredAt: row.dateOrNil(7), deliveredAt: row.dateOrNil(8), createdAt: row.date(9),
      modifiedAt: row.date(10))
  }
}

/// 一条记忆是谁记的。
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
  /// 忘掉的时刻。
  public var deletedAt: Date?

  /// 一条最多这么多字节（UTF-8），超了拒绝。
  public static let maxBytes = 280
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

/// 记忆里对齐的 2 的幂区间 [lo, hi) 的一行摘要（本机缓存，不同步）。区间里有行在摘要写下之后被忘掉、或行序变了（别处同步来更早的行），
/// 它就作废：读出时已滤掉（`CueMemory`）。
public struct CueMemorySummary: Equatable, Sendable {
  public var lo: Int
  public var hi: Int
  public var text: String
  public var createdAt: Date
}

/// 记忆的全貌：全部行（序号即下标，含忘掉的）与仍然有效的摘要，一次读出。记忆视图（`CueAgent`）从它算。
public struct CueMemory: Equatable, Sendable {
  public var lines: [CueMemoryLine]
  public var summaries: [CueMemorySummary]
}

/// Cue 的大脑跑在哪种 Agent 里。
public enum CueRuntime: String, Sendable, CaseIterable {
  case pi, codex, claude
}

/// Cue 的设置（同步，只有一行）。
public struct CueProfile: Equatable, Sendable {
  public var name: String
  /// 住在哪台 Mac（`PiSessionState.hostID` 同一种标识）；没选为 nil。
  public var hostID: String?
  public var runtime: Open<CueRuntime>
  public var model: String?
  public var effort: String?
  /// 启用的时刻；nil 是没启用。
  public var enabledAt: Date?
  public var modifiedAt: Date

  public static let defaultName = "Cue"
  /// 只有一行：任何设备上都是这个 id。
  static let recordID = DeterministicID.uuid("cue-profile")

  public init(
    name: String = CueProfile.defaultName, hostID: String? = nil, runtime: Open<CueRuntime> = .known(.pi), model: String? = nil,
    effort: String? = nil, enabledAt: Date? = nil, modifiedAt: Date = .now
  ) {
    self.name = name
    self.hostID = hostID
    self.runtime = runtime
    self.model = model
    self.effort = effort
    self.enabledAt = enabledAt
    self.modifiedAt = modifiedAt
  }
}

extension CueProfile: Record {
  static let table = Table.cueProfile
  static let columns = ["id", "name", "hostID", "runtime", "model", "effort", "enabledAt", "modifiedAt"]
  var bindings: [any SQLBindable] { [Self.recordID, name, hostID, runtime.rawValue, model, effort, enabledAt, modifiedAt] }
  init(row: Row) {
    let name = row.text(1).trimmingCharacters(in: .whitespacesAndNewlines)
    self.init(
      name: name.isEmpty ? Self.defaultName : name, hostID: row.textOrNil(2), runtime: Open(rawValue: row.text(3)),
      model: row.textOrNil(4), effort: row.textOrNil(5), enabledAt: row.dateOrNil(6), modifiedAt: row.date(7))
  }
}
