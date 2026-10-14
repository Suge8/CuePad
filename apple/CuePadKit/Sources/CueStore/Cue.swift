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
  /// 给你的选项；有选项的 Cue 消息在等你（规则见 `CueStore.cueMessagesWaitingForYou`）。
  public var choices: [String]?
  /// 要推送到手机。
  public var urgent: Bool
  /// 关联的卡片。
  public var taskID: UUID?
  public var answer: String?
  public var answeredAt: Date?
  /// 你的消息（或 Cue 的"等你"上你的回答）被交给 Cue 的大脑的时刻（由 Cue 住的那台 Mac 写）；回答改过、晚于它时要再交一次。
  public var deliveredAt: Date?
  public var createdAt: Date
  public var modifiedAt: Date
  /// 手机推送的标志（明文、可查询，服务端订阅按它出通知）：值班的 Mac 按通知规则置位，随那一次上传送出后清掉，
  /// 远端带回来的不留（同 `PiSessionState.notify`，见 docs/sync.md「Agent 锁屏通知」）。
  var notify: Bool = false
}

extension CueMessage: Record {
  static let table = Table.cueMessages
  static let columns = [
    "id", "author", "text", "choices", "urgent", "taskID", "answer", "answeredAt", "deliveredAt", "createdAt", "modifiedAt", "notify",
  ]
  /// `notify` 的值（订阅的谓词按它）。
  package static let notifyFlag = "cue"
  var bindings: [any SQLBindable] {
    [id, author.rawValue, text, choices.map { JSONColumn.encode($0) }, urgent, taskID, answer, answeredAt, deliveredAt, createdAt, modifiedAt, notify ? Self.notifyFlag : nil]
  }
  init(row: Row) {
    self.init(
      id: row.uuid(0), author: Open(rawValue: row.text(1)), text: row.text(2),
      choices: JSONColumn.decode([String].self, from: row.textOrNil(3)), urgent: row.bool(4), taskID: row.uuidOrNil(5),
      answer: row.textOrNil(6), answeredAt: row.dateOrNil(7), deliveredAt: row.dateOrNil(8), createdAt: row.date(9),
      modifiedAt: row.date(10), notify: row.textOrNil(11) != nil)
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

  /// 这段话能记成一条（去掉首尾空白后不空、不超过 `maxBytes` 字节）：界面输入时与写入时同一个判断。
  public static func fits(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed.utf8.count <= maxBytes
  }
}

/// 记忆的版本读数：行数、最后改动（记、忘、钉、提醒）与摘要的变化，任一变了它就变。管理器订阅它，不必每次读整份记忆。
public struct CueMemoryVersion: Equatable, Sendable {
  public var lines: Int
  public var linesModifiedAt: Date?
  public var summaries: Int
  public var summariesWrittenAt: Date?
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
  /// 思考强度：三种运行时都用这一个枚举，各家在大脑里映射。
  public var effort: Open<PiThinkingLevel>?
  /// 启用的时刻；nil 是没启用。
  public var enabledAt: Date?
  public var modifiedAt: Date

  /// 在值班的那台 Mac：启用了才有（停用后 `hostID` 还留着，但谁都不该再替 Cue 派活）。
  public var activeHost: String? { enabledAt == nil ? nil : hostID }

  public static let defaultName = "Cue"
  /// 只有一行：任何设备上都是这个 id。
  public static let recordID = DeterministicID.uuid("cue-profile")
  /// 它在 CloudKit 里的记录名（通知服务扩展取 Cue 的名字用）。
  package static var syncRecordName: String { recordID.uuidString.lowercased() }

  public init(
    name: String = CueProfile.defaultName, hostID: String? = nil, runtime: Open<CueRuntime> = .known(.pi), model: String? = nil,
    effort: Open<PiThinkingLevel>? = nil, enabledAt: Date? = nil, modifiedAt: Date = .now
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
  var bindings: [any SQLBindable] { [Self.recordID, name, hostID, runtime.rawValue, model, effort?.rawValue, enabledAt, modifiedAt] }
  init(row: Row) {
    let name = row.text(1).trimmingCharacters(in: .whitespacesAndNewlines)
    self.init(
      name: name.isEmpty ? Self.defaultName : name, hostID: row.textOrNil(2), runtime: Open(rawValue: row.text(3)),
      model: row.textOrNil(4), effort: row.textOrNil(5).map(Open.init(rawValue:)), enabledAt: row.dateOrNil(6), modifiedAt: row.date(7))
  }
}

/// Cue 通知的文案（Mac 本机通知与手机锁屏通知同一条规则）：标题是 Cue 的名字（空的用 `CueProfile.defaultName`），
/// 正文是那条消息的文字（去掉图片，至多 `bodyLimit` 字），"等你"再附上选项。
public enum CueAlert {
  public static let bodyLimit = 300

  public static func content(name: String?, text: String, choices: [String]?) -> (title: String, body: String) {
    var body = CueFormat.plainText(text).trimmingCharacters(in: .whitespacesAndNewlines)
    if body.count > bodyLimit { body = String(body.prefix(bodyLimit - 1)) + "…" }
    if let choices, !choices.isEmpty { body += "\n" + choices.joined(separator: " / ") }
    let name = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (name.isEmpty ? CueProfile.defaultName : name, body)
  }
}
