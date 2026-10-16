import CueText
import Foundation

// Cue：常驻的总控 Agent。它不写代码，只经 CuePad 的任务派活、跟进、问你、记东西。这里是它的数据：
// 对话（`cueMessages`）、记忆（`cueLines` 与本机的摘要缓存 `cueSummaries`）、设置（`cueProfile`）、此刻在做什么（`cueState`）。
// 值班时它管没做完的事与不归没做完的事的活会话（`CueStore.cueBoard`），不另记"由谁跟进"。

/// Cue 页对话里一行是谁的。
public enum CueAuthor: String, Sendable, CaseIterable {
  /// 你对 Cue 说的
  case you
  /// Cue 对你说的；带选项的是"等你"
  case cue
  /// Cue 自己醒来那一轮的动态（折叠显示）；没有正文的是那一轮的经过（`tools`）
  case note
  /// Cue 请求换新上下文时写的交接备忘
  case handoff
  /// 你发起的一轮的经过（`tools`，没有正文）：排在这一轮开始的位置，这一轮说的话与结果都在它之后（`CueStore.recordCueRound`）。
  /// Cue 自己醒来的一轮的经过是一条没有正文的动态（`note`），跟着动态收起
  case round
}

/// Cue 页的对话：Cue 对话唯一的事实源（不读运行时的会话文件）。写入后只有提问的结束（`answer`、`answeredAt`）与送达（`deliveredAt`）会变；
/// 一轮的经过那一行（`round`，或没有正文的 `note`）随这一轮做到哪改它的清单。
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
  /// 你选的那一项，或你不选、另外说的话（不在 `choices` 里）；Cue 撤回的为 nil。
  public var answer: String?
  /// 提问结束的时刻。
  public var answeredAt: Date?
  /// 你的消息或回答被交给 Cue 的大脑的时刻（由 Cue 住的那台 Mac 写）；回答晚于它时（别的设备同步来的另一个回答）要再交一次。
  public var deliveredAt: Date?
  public var createdAt: Date
  public var modifiedAt: Date
  /// 一轮的经过那一行的清单（Cue 那一轮调过的工具，`CueActivity`），与回答注脚同一个样子；别的行没有。
  public var tools: PiChatMessage.Tools?
  /// 手机推送的标志（明文、可查询，服务端订阅按它出通知）：值班的 Mac 按通知规则置位，随那一次上传送出后清掉，
  /// 远端带回来的不留（同 `PiSessionState.notify`，见 docs/sync.md「Agent 与 Cue 的通知」）。
  var notify: Bool = false
}

/// 新上下文接上的（`CueStore.cueResume`）：最近一份交接备忘与它之后的对话。
public struct CueResume: Equatable, Sendable {
  /// 没写过交接为 nil
  public var handoff: CueMessage?
  /// 交接之后的对话，从早到晚
  public var messages: [CueMessage]
  /// 更早的还有，没取
  public var truncated: Bool

  public init(handoff: CueMessage?, messages: [CueMessage], truncated: Bool) {
    self.handoff = handoff
    self.messages = messages
    self.truncated = truncated
  }
}

extension CueMessage: Record {
  static let table = Table.cueMessages
  static let columns = [
    "id", "author", "text", "choices", "urgent", "taskID", "answer", "answeredAt", "deliveredAt", "createdAt", "modifiedAt", "notify", "tools",
  ]
  /// `notify` 的值（订阅的谓词按它）。
  package static let notifyFlag = "cue"
  var bindings: [any SQLBindable] {
    [
      id, author.rawValue, text, choices.map { JSONColumn.encode($0) }, urgent, taskID, answer, answeredAt, deliveredAt, createdAt, modifiedAt,
      notify ? Self.notifyFlag : nil, tools?.stored,
    ]
  }
  init(row: Row) {
    self.init(
      id: row.uuid(0), author: Open(rawValue: row.text(1)), text: row.text(2),
      choices: JSONColumn.decode([String].self, from: row.textOrNil(3)), urgent: row.bool(4), taskID: row.uuidOrNil(5),
      answer: row.textOrNil(6), answeredAt: row.dateOrNil(7), deliveredAt: row.dateOrNil(8), createdAt: row.date(9),
      modifiedAt: row.date(10), tools: row.textOrNil(12).flatMap(PiChatMessage.Tools.init(stored:)), notify: row.textOrNil(11) != nil)
  }
}

/// 一条提问怎么结束（`CueStore.endCueQuestion`）：两种结局落到同一个状态上（`CueMessage.answeredAt`）。
/// 卡片一直挂着，直到你回答或 Cue 撤回，没有"关掉"。
public enum CueQuestionEnd: Equatable, Sendable {
  /// 你选了一项，或不选、另外说了一句（"不行，另外说…"）：都交给 Cue、叫醒它
  case answered(String)
  /// Cue 撤回了（拿了主意或情况变了）：它自己撤的，不交给它
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
  /// 大脑跑在哪家 Agent 里（`runtimes` 之一）
  public var runtime: Open<AgentKind>
  /// 大脑用的模型，按 `runtime` 那家的写法（`AgentKind.modelRef`）；nil 是用这家自己的默认。
  public var model: String?
  /// 思考强度：三种运行时都用这一个枚举，各家在大脑里映射。全新的设置是低（大脑默认要快）；nil 是交给运行时取档。
  public var effort: Open<PiThinkingLevel>?
  /// 启用的时刻；nil 是没启用。
  public var enabledAt: Date?
  /// 允许清单：哪几类要先问的事以后不用问（唯一的事实源）。卡片上的"以后……都不用问"、设置里的开关与 Cue 的 `memory allow` 都写这里，
  /// Cue 的 `tell` 带 `ask` 时查它（`CueStore.addCueMessage`）。
  public var allows: Set<CueAllow>
  public var modifiedAt: Date

  /// 在值班的那台 Mac：启用了才有（停用后 `hostID` 还留着，但谁都不该再替 Cue 派活）。
  public var activeHost: String? { enabledAt == nil ? nil : hostID }

  /// Cue 在值班（唯一规则）：启用了，它住的那台 Mac 在线（`hostOnline`，那台的在线记录 `MacPresence`），大脑也没停在起不来（`state` 不是出错）。
  /// 值班时会话等的回答 CuePad 答得了就归 Cue（`PiSessionState.asksYou`），不算等你；它住的那台 Mac 的管理器是否在跑由那台的 `activeHost` 定，与这里同源。
  public func onDuty(_ state: CueState?, hostOnline: Bool) -> Bool { activeHost != nil && hostOnline && state?.state != .known(.error) }

  public static let defaultName = "Cue"
  /// 能当大脑的几家，按启用时挑选的顺序（OpenCode 不能当大脑）：Mac 查本机能用的、两端 Cue 页的模型菜单都按它。
  public static let runtimes: [AgentKind] = [.pi, .codex, .claudeCode]
  /// 只有一行：任何设备上都是这个 id。
  public static let recordID = DeterministicID.uuid("cue-profile")
  /// 它在 CloudKit 里的记录名（通知服务扩展取 Cue 的名字用）。
  public static var syncRecordName: String { recordID.uuidString.lowercased() }

  public init(
    name: String = CueProfile.defaultName, hostID: String? = nil, runtime: Open<AgentKind> = .known(.pi), model: String? = nil,
    effort: Open<PiThinkingLevel>? = .known(.low), enabledAt: Date? = nil, allows: Set<CueAllow> = [], modifiedAt: Date = .now
  ) {
    self.name = name
    self.hostID = hostID
    self.runtime = runtime
    self.model = model
    self.effort = effort
    self.enabledAt = enabledAt
    self.allows = allows
    self.modifiedAt = modifiedAt
  }

  /// 这类事在这个项目里（`project` 为 nil 是不在项目里的事）已允许：清单里有不分项目的那一项，或这个项目的那一项。返回对上的那一项。
  public func allowing(_ ask: CueAsk, in project: UUID?) -> CueAllow? {
    [CueAllow(ask, project: nil), project.map { CueAllow(ask, project: $0) }].compactMap(\.self).first(where: allows.contains)
  }
}

extension CueProfile: Record {
  static let table = Table.cueProfile
  static let columns = ["id", "name", "hostID", "runtime", "model", "effort", "enabledAt", "modifiedAt", "allows"]
  var bindings: [any SQLBindable] {
    [Self.recordID, name, hostID, runtime.rawValue, model, effort?.rawValue, enabledAt, modifiedAt, CueAllow.encode(allows)]
  }
  init(row: Row) {
    let name = row.text(1).trimmingCharacters(in: .whitespacesAndNewlines)
    self.init(
      name: name.isEmpty ? Self.defaultName : name, hostID: row.textOrNil(2), runtime: Open(rawValue: row.text(3)),
      model: row.textOrNil(4), effort: row.textOrNil(5).map(Open.init(rawValue:)), enabledAt: row.dateOrNil(6),
      allows: CueAllow.decode(row.textOrNil(8)), modifiedAt: row.date(7))
  }
}

/// Cue 此刻在做什么（同步，只有一行，只由它值班的那台 Mac 写）：与 Agent 会话同一套工作状态（`PiWorkState`）。
/// 一轮里是思考（`thinking`）或调用工具（`tool`，`detail` 是"动作 · 目标"，同会话的工具说明），一轮之间歇着（`settled`），
/// 大脑起不来是出错（`error`，`detail` 是原因）。别的设备与这台 Mac 的界面都只读它（`CuePresence`）。
public struct CueState: Equatable, Sendable {
  public var state: Open<PiWorkState>
  /// 正在跑的那一步（"动作 · 目标"，`CueActivity.detail`）
  public var detail: String?
  /// 在跑的这一轮的经过那一行（`CueStore.recordCueRound`）；还没调过工具、歇着时没有
  public var round: UUID?
  /// 在跑的这一轮是会话的动静叫醒的（`CueWake.sessionActivity`）；别的原因醒来、歇着时没有
  public var woke: CueWoke?
  public var modifiedAt: Date

  public init(state: Open<PiWorkState>, detail: String? = nil, round: UUID? = nil, woke: CueWoke? = nil, modifiedAt: Date = .now) {
    self.state = state
    self.detail = detail
    self.round = round
    self.woke = woke
    self.modifiedAt = modifiedAt
  }

  static let recordID = DeterministicID.uuid("cue-state")
}

/// 叫醒 Cue 这一轮的会话动静：醒来的时刻（一轮一个，接连几次叫醒各是各的）与带来变化的那几个会话（`CueChange.session`；
/// 只有任务完成、不在会话上的变化时为空）。只在值班的 Mac 起这一轮时定下、随 `CueState` 同步，各端画"叫醒"的那一下只读它。
public struct CueWoke: StoredJSON, Equatable, Sendable {
  public var at: Date
  public var sessions: [String]

  public init(at: Date, sessions: [String]) {
    self.at = at
    self.sessions = sessions
  }
}

extension CueState: Record {
  static let table = Table.cueState
  static let columns = ["id", "state", "detail", "modifiedAt", "round", "woke"]
  var bindings: [any SQLBindable] { [Self.recordID, state.rawValue, detail, modifiedAt, round, woke?.stored] }
  init(row: Row) {
    self.init(
      state: Open(rawValue: row.text(1)), detail: row.textOrNil(2), round: row.uuidOrNil(4), woke: row.textOrNil(5).flatMap(CueWoke.init(stored:)),
      modifiedAt: row.date(3))
  }
}

/// Cue 要先问你的几类事（唯一定义，Cue 的提示词与工具说明照它写）：收不回或越出它职责的事。只有这几类能写带选项的"等你"
/// （`CueStore.addCueMessage` 的 `ask`）；调研方案、设计取舍、实现路线、步骤与整件事算不算做完，Cue 按你的规矩与最佳实践自己定，做完告诉你。
/// 选项也由这里给（`choices`），Cue 不能自拟"照这个做 / 我再看看"这类确认；不允许就在卡片的输入框里另外说（`otherwise`）。
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
  /// 卡片上选项之后的输入框：不允许，写下你的话（作为回答交给 Cue，叫醒它）。
  public static let otherwise = "不行，另外说…"

  /// 选了它，这类事以后就不再问：`CueStore.endCueQuestion` 把它记进允许清单（`CueProfile.allows`，问的事关联的任务在项目里时只管这个项目）。
  /// 规矩那一类没有这一项：一律放行等于没有规矩。
  public var always: String? { self == .rule ? nil : "以后\(name)都不用问" }

  public var choices: [String] { [Self.once] + (always.map { [$0] } ?? []) }

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
}

/// 允许清单里的一项（`CueProfile.allows`）：一类要先问的事在一个项目里（`project`），或所有项目里（nil）以后不用问。
/// 存成"类别"或"类别/项目 id"的数组；更新的版本写的类别原样留着（`Open`），改清单时不丢。
public struct CueAllow: Hashable, Sendable {
  public var ask: Open<CueAsk>
  public var project: UUID?

  public init(_ ask: CueAsk, project: UUID?) {
    self.ask = .known(ask)
    self.project = project
  }

  init?(stored: String) {
    let parts = stored.split(separator: "/", maxSplits: 1).map(String.init)
    guard let raw = parts.first else { return nil }
    ask = Open(rawValue: raw)
    project = parts.count > 1 ? UUID(uuidString: parts[1]) : nil
  }

  var stored: String { ask.rawValue + (project.map { "/" + $0.uuidString.lowercased() } ?? "") }

  static func encode(_ allows: Set<CueAllow>) -> String? { JSONColumn.encodeList(allows.map(\.stored).sorted()) }
  static func decode(_ text: String?) -> Set<CueAllow> { Set(JSONColumn.decodeList(String.self, from: text).compactMap(CueAllow.init(stored:))) }
}

/// Cue 做完一件顶层任务后告诉你的结果（`CueStore.finishTask`）：一行"「任务名」做完了"，下面每条证据一个要点。
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
