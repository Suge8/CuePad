import CueText
import Foundation

// Cue：常驻的总控 Agent。它不写代码，只经 CuePad 的任务派活、跟进、问你、记东西。这里是它的数据：
// 对话（`cueMessages`）、记忆（`cueLines` 与本机的摘要缓存 `cueSummaries`）、设置（`cueProfile`）、此刻在做什么（`cueState`）。
// 值班时它管所有有活会话、没做完的事（`CueStore.cueBoard`），不另记"由谁跟进"。

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

/// Cue 页的对话：Cue 对话唯一的事实源（不读运行时的会话文件）。写入后只有提问的结束（`answer`、`answeredAt`）与送达（`deliveredAt`）会变。
/// 带选项的是提问，只有一个状态：`answeredAt` 为空是开着，有值是结束了（`CueStore.endCueQuestion`，结束了不再变）。
public struct CueMessage: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var author: Open<CueAuthor>
  /// 正文（`CueFormat`）；你的消息可带图片引用。
  public var text: String
  /// 给你的选项；有选项的 Cue 消息在等你（规则见 `CueStore.cueMessagesWaitingForYou`）。选项只由 `CueAsk` 给出、Cue 不能自拟，
  /// 所以你选的那一项就说明了是哪类事（`CueAsk.always`）。
  public var choices: [String]?
  /// 带选项的是哪一类"等你"（`CueAsk.init(choices:)`）。
  public var ask: CueAsk? { choices.map(CueAsk.init(choices:)) }
  /// 要推送到手机。
  public var urgent: Bool
  /// 关联的卡片。
  public var taskID: UUID?
  /// 你选的那一项；没选就结束的（你关掉、Cue 撤回）为 nil。
  public var answer: String?
  /// 提问结束的时刻。
  public var answeredAt: Date?
  /// 你的消息（或 Cue 的提问怎么结束的）被交给 Cue 的大脑的时刻（由 Cue 住的那台 Mac 写）；结束晚于它时（别的设备同步来的另一个结局）要再交一次。
  /// Cue 撤回的结束时同时写上：它自己撤的，不用再告诉它。
  public var deliveredAt: Date?
  public var createdAt: Date
  public var modifiedAt: Date
  /// 手机推送的标志（明文、可查询，服务端订阅按它出通知）：值班的 Mac 按通知规则置位，随那一次上传送出后清掉，
  /// 远端带回来的不留（同 `PiSessionState.notify`，见 docs/sync.md「Agent 与 Cue 的通知」）。
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
    [
      id, author.rawValue, text, choices.map { JSONColumn.encode($0) }, urgent, taskID, answer, answeredAt, deliveredAt, createdAt, modifiedAt,
      notify ? Self.notifyFlag : nil,
    ]
  }
  init(row: Row) {
    self.init(
      id: row.uuid(0), author: Open(rawValue: row.text(1)), text: row.text(2),
      choices: JSONColumn.decode([String].self, from: row.textOrNil(3)), urgent: row.bool(4), taskID: row.uuidOrNil(5),
      answer: row.textOrNil(6), answeredAt: row.dateOrNil(7), deliveredAt: row.dateOrNil(8), createdAt: row.date(9),
      modifiedAt: row.date(10), notify: row.textOrNil(11) != nil)
  }
}

extension CueMessage {
  /// 待交给 Cue 的这一条（`CueStore.cueMessagesToDeliver`）要不要叫醒它：你的话与选了的回答要；你关掉的提问不用，随下一次醒来的信封交。
  public var wakesCue: Bool { author == .known(.you) || answer != nil }
}

/// 一条提问怎么结束（`CueStore.endCueQuestion`）：几种结局落到同一个状态上（`CueMessage.answeredAt`）。答了的记下选的那一项，
/// 关掉与撤回都没选（`answer` 为 nil），撤回的同时记送达。
public enum CueQuestionEnd: Equatable, Sendable {
  /// 你选了一项
  case answered(String)
  /// 你关掉了：不叫醒 Cue，它下次醒来在信封的变化里看到
  case dismissed
  /// Cue 撤回了（拿了主意或情况变了）
  case withdrawn
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

/// Cue 的设置（同步，只有一行）。
public struct CueProfile: Equatable, Sendable {
  public var name: String
  /// 住在哪台 Mac（`PiSessionState.hostID` 同一种标识）；没选为 nil。
  public var hostID: String?
  /// 大脑跑在哪家 Agent 里（OpenCode 不能当大脑）
  public var runtime: Open<AgentKind>
  public var model: String?
  /// 思考强度：三种运行时都用这一个枚举，各家在大脑里映射。全新的设置是低（大脑默认要快）；nil 是交给运行时取档。
  public var effort: Open<PiThinkingLevel>?
  /// 启用的时刻；nil 是没启用。
  public var enabledAt: Date?
  public var modifiedAt: Date

  /// 在值班的那台 Mac：启用了才有（停用后 `hostID` 还留着，但谁都不该再替 Cue 派活）。
  public var activeHost: String? { enabledAt == nil ? nil : hostID }

  /// Cue 在值班（唯一规则）：启用了，它住的那台 Mac 有回应（`asleep` 见 `CueStore.cueAsleep`），大脑也没停在起不来（`state` 不是出错）。
  /// 值班时会话等的回答 CuePad 答得了就归 Cue（`PiSessionState.asksYou`），不算等你；它住的那台 Mac 的管理器是否在跑由那台的 `activeHost` 定，与这里同源。
  public func onDuty(_ state: CueState?, asleep: Bool) -> Bool { activeHost != nil && !asleep && state?.state != .known(.error) }

  public static let defaultName = "Cue"
  /// 只有一行：任何设备上都是这个 id。
  public static let recordID = DeterministicID.uuid("cue-profile")
  /// 它在 CloudKit 里的记录名（通知服务扩展取 Cue 的名字用）。
  public static var syncRecordName: String { recordID.uuidString.lowercased() }

  public init(
    name: String = CueProfile.defaultName, hostID: String? = nil, runtime: Open<AgentKind> = .known(.pi), model: String? = nil,
    effort: Open<PiThinkingLevel>? = .known(.low), enabledAt: Date? = nil, modifiedAt: Date = .now
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

/// Cue 此刻在做什么（同步，只有一行，只由它值班的那台 Mac 写）：与 Agent 会话同一套工作状态（`PiWorkState`）。
/// 一轮里是思考（`thinking`）或调用工具（`tool`，`detail` 是"动作 · 目标"，同会话的工具说明），一轮之间歇着（`settled`），
/// 大脑起不来是出错（`error`，`detail` 是原因）。别的设备与这台 Mac 的界面都只读它（`CuePresence`）。
public struct CueState: Equatable, Sendable {
  public var state: Open<PiWorkState>
  public var detail: String?
  public var modifiedAt: Date

  public init(state: Open<PiWorkState>, detail: String? = nil, modifiedAt: Date = .now) {
    self.state = state
    self.detail = detail
    self.modifiedAt = modifiedAt
  }

  static let recordID = DeterministicID.uuid("cue-state")
}

extension CueState: Record {
  static let table = Table.cueState
  static let columns = ["id", "state", "detail", "modifiedAt"]
  var bindings: [any SQLBindable] { [Self.recordID, state.rawValue, detail, modifiedAt] }
  init(row: Row) { self.init(state: Open(rawValue: row.text(1)), detail: row.textOrNil(2), modifiedAt: row.date(3)) }
}

/// Cue 要先问你的几类事（唯一定义，Cue 的提示词与工具说明照它写）：收不回或越出它职责的事。只有这几类能写带选项的"等你"
/// （`CueStore.addCueMessage` 的 `ask`）；调研方案、设计取舍、实现路线、步骤与整件事的验收，Cue 按你的规矩与最佳实践自己定，做完告诉你。
/// 选项也由这里给（`choices`），Cue 不能自拟"照这个做 / 我再看看"这类确认。
public enum CueAsk: String, CaseIterable, Sendable {
  case push, merge, release, delete, outside, budget, rule

  /// 这类事的说法（"以后推送都不用问"；改规矩那一类只给 Cue 看）。
  public var name: String {
    switch self {
    case .push: "推送"
    case .merge: "合并到共享分支"
    case .release: "发布或部署"
    case .delete: "删除"
    case .outside: "动项目以外的东西"
    case .budget: "超出预算"
    case .rule: "违反或改动用户的规矩，或他的规矩要你先问的事"
    }
  }

  public static let once = "允许一次"
  public static let deny = "拒绝"

  /// 选了它，这类事以后就不再问：`CueStore.endCueQuestion` 记一条你的、一直记着的规矩（`rule(project:)`）。
  /// 规矩那一类没有这一项：一律放行等于没有规矩。
  public var always: String? { self == .rule ? nil : "以后\(name)都不用问" }

  public var choices: [String] { [Self.once] + (always.map { [$0] } ?? []) + [Self.deny] }

  /// 由一条"等你"的选项认出是哪一类：选项只由 `choices` 写出，带"以后……都不用问"的是那一类，不带的是规矩那一类。
  public init(choices: [String]) {
    self = Self.allCases.first { $0.always.map(choices.contains) ?? false } ?? .rule
  }

  /// 一条"等你"在 Cue 页以外的说法（卡片第一句、侧栏与菜单栏的摘要、小组件、本机与手机通知同一句）：要你定什么，
  /// 按类别与关联任务的标题（`Card.heading`，没有或空白时不写）由代码写出；Cue 的原话只在 Cue 页的卡片里点开看。
  public func question(task: String?) -> String {
    let named = task.flatMap { $0.isEmpty ? nil : "「\($0)」" } ?? ""
    return switch self {
    case .push: "要不要推送\(named)？"
    case .merge: "要不要把\(named.isEmpty ? "改动" : named)合并到共享分支？"
    case .release: "要不要发布或部署\(named)？"
    case .delete: "\(named)要删除东西，允许吗？"
    case .outside: "\(named)要动项目以外的东西，允许吗？"
    case .budget: "\(named)要超出预算，允许吗？"
    case .rule: "\(named)这一步按你的规矩要先问，允许吗？"
    }
  }

  /// "以后都不用问"记成的规矩原文；问的事关联的任务在项目里时只管这个项目。Cue 再问同一类事，库里有这一行（没忘掉、一直记着）就拒绝。
  public func rule(project: String?) -> String? {
    always.map { always in project.map { "\(always)（项目「\($0)」）" } ?? always }
  }
}

/// Cue 收尾一件顶层任务后告诉你的结果（`CueStore.finishTask`）：一行"「任务名」做完了"，下面每条证据一个要点。
public enum CueReport {
  public static func text(task: String, evidence: [String]) -> String {
    (["「\(task)」做完了", ""] + evidence.map { "- \($0)" }).joined(separator: "\n")
  }
}

/// Cue 通知的文案（Mac 本机通知与手机锁屏通知同一条规则）：标题是 Cue 的名字（空的用 `CueProfile.defaultName`）；
/// "等你"的正文是要你定什么（`CueAsk.question`，`task` 是关联任务的标题）接选项，不露原话；其余是那条消息的文字（去掉图片，至多 `bodyLimit` 字）。
public enum CueAlert {
  public static let bodyLimit = 300

  public static func content(name: String?, text: String, choices: [String]?, task: String?) -> (title: String, body: String) {
    var body: String
    if let choices {
      body = CueAsk(choices: choices).question(task: task) + "\n" + choices.joined(separator: " / ")
    } else {
      body = CueFormat.plainText(text).trimmingCharacters(in: .whitespacesAndNewlines)
      if body.count > bodyLimit { body = String(body.prefix(bodyLimit - 1)) + "…" }
    }
    let name = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (name.isEmpty ? CueProfile.defaultName : name, body)
  }
}
