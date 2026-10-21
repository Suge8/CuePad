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
  /// Cue 自己醒来那一轮的动态（不推送，Cue 页收进一颗虚线气泡）：没有正文的是那一轮的经过，带着它为什么醒（`wake`）与做了什么（`tools`）
  case note
  /// Cue 请求换新上下文时写的交接备忘
  case handoff
  /// 你发起的一轮的经过（`tools`，没有正文）：排在这一轮开始的位置，这一轮说的话与结果都在它之后（`CueStore.recordCueRound`）。
  /// Cue 自己醒来的一轮的经过是一条没有正文的动态（`note`），跟着动态收起
  case round
}

/// Cue 页的对话：Cue 对话唯一的事实源（不读运行时的会话文件）。写入后只有提问的结束（`answer`、`answeredAt`）与送达（`deliveredAt`）会变；
/// 一轮的经过那一行（`round`，或没有正文的 `note`）随这一轮做到哪改它的清单。
/// 带选项的是提问，只有一个状态：`answeredAt` 为空是开着，有值是结束了（`CueQuestionEnd`）；结束了不再变，只有你开口收起的 Cue 放得回。
public struct CueMessage: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var author: Open<CueAuthor>
  /// 正文（`CueFormat`）；你的消息可带图片引用。
  public var text: String
  /// 给你的选项；有选项的 Cue 消息在等你（规则见 `CueStore.cueMessagesWaitingForYou`）。选项只由 `CueAsk.choices` 在写入时按 `asked` 写出、
  /// Cue 不能自拟；写下就不再变，卡片与通知照它显示。
  public var choices: [String]?
  /// 提问的类别与范围（明文、同步，写入时定下）：哪一类事，与关联任务当时所在的项目（没关联任务为 nil，是所有项目）。
  /// 选项里"以后……不用问"照它写，选了就把它原样记进允许清单（`CueStore.endCueQuestion`），所以字面范围与实际放行的一致。
  /// 结构 56 之前写的提问由升级按当时的选项补上（`Schema.backfillAsked`）。
  public var asked: CueAllow?
  /// 提问要做的动作与依据的规矩（`CueAsking`；用户内容，加密同步）。
  public var askAction: String?
  public var askRule: String?
  /// Cue 点名要你看的图，按它给的先后（`CueShot.checked`）：提问的是回答它必须看的，做完的结果是证明结论的最终成果（`CueStore.finishTask`）。
  /// 卡片、通知与全屏预览只读它，没点名的没有图。看什么是用户内容，加密同步；列与同步字段沿用最初只有提问时的名字 askShots（同步表不改已有列）。
  public var shots: [CueShot] = []
  /// 提问是哪一类事。
  public var ask: CueAsk? { asked?.ask.known }
  /// 提问问的是什么（`CueAsking.init(stored:)`）；不是提问，或是认不出类别、没有动作短语的提问为 nil。
  public var asking: CueAsking? { CueAsking(stored: ask, action: askAction, rule: askRule) }
  /// 要提示你（推到手机、Mac 发通知）：Cue 用 tell 标的急事，与你在等的——回答你那一轮的回复或出错（这一轮还没提示过你时，`replyCueRound`），
  /// Cue 起不来（`CueKeeper`）。
  public var urgent: Bool
  /// 关联的卡片。
  public var taskID: UUID?
  /// 你选的那一项（`choices` 之一；更旧版本存下的可能是卡上另外写的一句，照原文显示）；收起、撤回的为 nil。
  public var answer: String?
  /// 提问结束的时刻。
  public var answeredAt: Date?
  /// 你开口收起这条提问的那句话（你的消息的 id，`CueQuestionEnd`）；放回"等你"时清掉。
  public var setAsideBy: UUID?
  /// 你的消息或回答被交给 Cue 的大脑的时刻（由 Cue 运行的那台 Mac 写）；回答晚于它时（别的设备同步来的另一个回答）要再交一次。
  public var deliveredAt: Date?
  public var createdAt: Date
  public var modifiedAt: Date
  /// 一轮的经过那一行的清单（Cue 那一轮调过的工具，`CueActivity`），与回答注脚同一个样子；别的行没有。
  public var tools: PiChatMessage.Tools?
  /// Cue 自己醒来的那一轮为什么醒（只在它的经过那一行上，起这一轮时写下、不再变）：Cue 页那一节的第一行与叫醒的接力都只读它。
  public var wake: CueWake? = nil
  /// 手机推送的标志（明文、可查询，服务端订阅按它出通知）：写下时按 `alerts` 与他在不在 Mac 上开着 Cue 页置位（`CueStore.insertCueMessage`），
  /// 随那一次上传送出后清掉，远端带回来的不留（同 `PiSessionState.notify`，见 docs/sync.md「Agent 与 Cue 的通知」）。
  var notify: Bool = false

  /// 要提示你的 Cue 消息（手机推送与 Mac 通知同一条规则）：Cue 对你说的，带选项来问（"等你"）或 `urgent`。
  public var alerts: Bool { author == .known(.cue) && (choices != nil || urgent) }
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
    "ask", "askAction", "askRule", "askShots", "setAsideBy", "wake",
  ]
  /// `notify` 的值（订阅的谓词按它）。
  package static let notifyFlag = "cue"
  var bindings: [any SQLBindable] {
    [
      id, author.rawValue, text, choices.map { JSONColumn.encode($0) }, urgent, taskID, answer, answeredAt, deliveredAt, createdAt, modifiedAt,
      notify ? Self.notifyFlag : nil, tools?.stored, asked?.stored, askAction, askRule, JSONColumn.encodeList(shots), setAsideBy, wake?.stored,
    ]
  }
  init(row: Row) {
    self.init(
      id: row.uuid(0), author: Open(rawValue: row.text(1)), text: row.text(2),
      choices: JSONColumn.decode([String].self, from: row.textOrNil(3)), asked: row.textOrNil(13).flatMap(CueAllow.init(stored:)),
      askAction: row.textOrNil(14), askRule: row.textOrNil(15), shots: JSONColumn.decodeList(CueShot.self, from: row.textOrNil(16)), urgent: row.bool(4), taskID: row.uuidOrNil(5),
      answer: row.textOrNil(6), answeredAt: row.dateOrNil(7), setAsideBy: row.uuidOrNil(17), deliveredAt: row.dateOrNil(8), createdAt: row.date(9),
      modifiedAt: row.date(10), tools: row.textOrNil(12).flatMap(PiChatMessage.Tools.init(stored:)), wake: row.textOrNil(18).flatMap(CueWake.init(stored:)),
      notify: row.textOrNil(11) != nil)
  }
}

/// 一条提问怎么结束（`CueStore.endCueQuestion`）：几种结局落到同一个状态上（`CueMessage.answeredAt`），没有"关掉"。
/// 卡上只能选；你不选、在 Cue 页底下开口，还开着的卡当场收起，算你直接说了（`CueStore.addCueMessage`，记下是哪句话收起的，`CueMessage.setAsideBy`）。
/// 你的话也可能只是别的想法：Cue 读了判断不是在答它，就放回"等你"（`CueStore.restoreCueQuestion`）；那句没交给 Cue 就撤回了，也放回。
public enum CueQuestionEnd: Equatable, Sendable {
  /// 你选了一项（`choices` 之一）：交给 Cue、叫醒它
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
  /// 运行在哪台 Mac（`PiSessionState.hostID` 同一种标识）；没选为 nil。
  public var hostID: String?
  /// 大脑跑在哪家 Agent 里（`runtimes` 之一）
  public var runtime: Open<AgentKind>
  /// 大脑用的模型，按 `runtime` 那家的写法（`AgentKind.modelRef`）；nil 是用这家自己的默认。
  public var model: String?
  /// 思考强度：三种运行时都用这一个枚举，各家在大脑里映射。全新的设置是低（大脑默认要快）；nil 是交给运行时取档。
  public var effort: Open<PiThinkingLevel>?
  /// 启用的时刻；nil 是没启用。
  public var enabledAt: Date?
  /// 允许清单：哪几类要先问的事以后不用问（唯一的事实源）。卡片上的"以后……不用问"、设置里的开关与 Cue 的 `memory allow` 都写这里，
  /// Cue 的 `tell` 带 `ask` 时查它（`CueStore.addCueMessage`）。
  public var allows: Set<CueAllow>
  public var modifiedAt: Date

  /// 在值班的那台 Mac：启用了才有（停用后 `hostID` 还留着，但谁都不该再替 Cue 派活）。
  public var activeHost: String? { enabledAt == nil ? nil : hostID }

  /// Cue 在值班（唯一规则）：启用了，它运行的那台 Mac 在线（`hostOnline`，那台的在线记录 `MacPresence`），大脑也没停在起不来（`state` 不是出错）。
  /// 值班时会话等的回答 CuePad 答得了就归 Cue（`PiSessionState.asksYou`），不算等你；它运行的那台 Mac 的管理器是否在跑由那台的 `activeHost` 定，与这里同源。
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

  /// 这类事在这个项目里（`project` 为 nil 是不关联任务的事）已允许：清单里有不分项目的那一项，或这个项目的那一项。返回对上的那一项。
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
  /// 它这个班次的上下文（`CueContext`），值班的 Mac 随状态写；不在值班、这个班次还没请求过模型为 nil
  public var context: CueContext?
  /// 它留给你回的会话（`CueLeft`，只由 `CueStore.leaveToYou` 写，`setCueState` 不动它）
  public var left: [CueLeft]
  public var modifiedAt: Date

  public init(
    state: Open<PiWorkState>, detail: String? = nil, round: UUID? = nil, context: CueContext? = nil, left: [CueLeft] = [], modifiedAt: Date = .now
  ) {
    self.left = left
    self.state = state
    self.detail = detail
    self.round = round
    self.context = context
    self.modifiedAt = modifiedAt
  }

  static let recordID = DeterministicID.uuid("cue-state")
}

/// 你在 Cue 页读到哪（同步，只有一行，各端都写）：读到的那条 Cue 的话写下的时刻，就记成这一行的修改时间，没有别的列。
/// 同步时两个版本按修改时间取晚的（`CueStore.applyVersion`），本机也只往后挪（`CueStore.markCueRead`）：两台设备各读各的，
/// 谁也冲不掉另一台读得更远的；另记一列"读到哪"的话，按修改时间取胜的那一版可能读得更近。新消息的规则在 `CueStore.cueUnread`。
enum CueRead {
  static let recordID = DeterministicID.uuid("cue-read")
  static let columns = ["id", "modifiedAt"]
}

public enum CueEnableError: LocalizedError, Equatable {
  /// 那台 Mac 上没有能当大脑的 Agent（参数是各家为什么不能用，`MacAgents.whyNone`）
  case noRuntime(String)
  /// Cue 正在另一台 Mac 上运行（参数是那台的名字，`MacAgents.shownName`），这次没说要换过去
  case runsElsewhere(String)
  /// 这台的库还没和 iCloud 对过一遍：不知道 Cue 是否已在别的 Mac 上启用（App 层判断，`AppServices.enableCue`）
  case unsynced

  public var errorDescription: String? {
    switch self {
    case .noRuntime(let why): "那台 Mac 上没有能当 Cue 的 Agent：\(why)"
    case .runsElsewhere(let name): "正在「\(name)」上运行，换过去需先确认"
    case .unsynced: "还没和 iCloud 同步完"
    }
  }
}

/// Cue 此刻的上下文（一个班次一份）：用了多少 token、模型的窗口（大脑没报为 nil）、这个班次几点起。用到 `renewAt` 后，
/// 下一次醒来的信封要它先写交接备忘再换新（`CueEnvelope`）。随 `CueState` 同步，各端的上下文用量只读它。
public struct CueContext: StoredJSON, Equatable, Sendable {
  public var used: Int
  public var window: Int?
  public var since: Date

  /// 换新线：6 万 token。
  public static let renewAt = 60_000

  /// token 数的写法（各端的上下文用量与 Mac 的运行情况同一种）：不到一千写原数，往上写 5.3k、128k。
  public static func tokens(_ count: Int) -> String {
    count >= 1000 ? "\((Double(count) / 1000).formatted(.number.precision(.fractionLength(0...1))))k" : "\(count)"
  }

  public init(used: Int, window: Int?, since: Date) {
    self.used = used
    self.window = window
    self.since = since
  }
}

/// Cue 这一轮为什么醒（值班的管理器起一轮时定下）。交给大脑的信封照它写"醒来："；Cue 自己醒来的一轮把它记在这一轮的经过那一行上
/// （`CueMessage.wake`，随那一行同步），Cue 页那一节的第一行照它写、点了去叫醒它的会话，叫醒的接力（`CueFlight`）也只读它。
public enum CueWake: StoredJSON, Equatable, Sendable {
  /// 刚启用：第一次醒来
  case enabled
  /// 你发来新消息
  case message
  /// 在做的事里有动静（`CueChange`）：哪几处，按事件时刻从早到晚
  case sessionActivity([CueStir])
  /// 空闲时的例行查看（含合并记忆）
  case idle
  /// 提醒到点：到点的那几条记忆
  case reminder([UUID])
  /// 写下交接、换了新上下文：接着做（交接在信封的"接上"里）
  case renewed
  /// 他改了要换大脑的设置（名字、Agent，或模型、强度回到默认）：先写交接
  case settingsChanged
}

/// 叫醒 Cue 的一处动静：`CueChange` 里界面要的那点——出了什么事、在哪个会话、哪件任务。
public struct CueStir: Codable, Equatable, Sendable {
  public var kind: CueChange.Kind
  /// Pi 的会话 id；任务完成这类不在会话上的为 nil
  public var session: String?
  /// 变化所在的那件（叶子，任务本身的变化是任务）
  public var task: UUID?

  public init(kind: CueChange.Kind, session: String? = nil, task: UUID? = nil) {
    self.kind = kind
    self.session = session
    self.task = task
  }

  public init(_ change: CueChange) {
    self.init(kind: change.kind, session: change.session?.sessionID, task: (change.leaf ?? change.task)?.id)
  }
}

/// Cue 把会话的这一次停下留给你回（`CueStore.leaveToYou`）：会话停在 `since` 起的那次停下（歇着或等回答）时成立，
/// 谁再对它说话、它动起来（`stateSince` 变了）就自然作废，不用谁去清。只有一份：会话列表的"待回复"、等你确认与"等你 N"都经 `CueDuty` 读它。
public struct CueLeft: StoredJSON, Hashable, Sendable {
  public var sessionID: String
  public var since: Date

  public init(sessionID: String, since: Date) {
    self.sessionID = sessionID
    self.since = since
  }

  /// 这一条说的就是会话此刻的这次停下。
  public func holds(for session: PiSessionState) -> Bool {
    session.sessionID == sessionID && session.stateSince.stored == since.stored && session.state.known?.isStopped == true
  }
}

/// Cue 在值班时各端看会话要用的那一份（`CueStore.cueDuty`；不在值班为 nil）：它的名字（"等 X 回答"）与它留给你回的会话。
/// 会话等的是 Cue 还是你（`PiSessionState.waitsForCue`、`asksYou`）、会话行的"待回复"都只读它。
public struct CueDuty: Equatable, Sendable {
  public var name: String
  public var left: [CueLeft]

  public init(name: String, left: [CueLeft] = []) {
    self.name = name
    self.left = left
  }

  /// Cue 把会话此刻的这次停下留给了你。
  public func leftToYou(_ session: PiSessionState) -> Bool { left.contains { $0.holds(for: session) } }
}

extension CueState: Record {
  static let table = Table.cueState
  static let columns = ["id", "state", "detail", "modifiedAt", "round", "context", "leftToYou"]
  var bindings: [any SQLBindable] {
    [Self.recordID, state.rawValue, detail, modifiedAt, round, context?.stored, left.isEmpty ? nil : JSONColumn.encode(left)]
  }
  init(row: Row) {
    self.init(
      state: Open(rawValue: row.text(1)), detail: row.textOrNil(2), round: row.uuidOrNil(4), context: row.textOrNil(5).flatMap(CueContext.init(stored:)),
      left: JSONColumn.decodeList(CueLeft.self, from: row.textOrNil(6)), modifiedAt: row.date(3))
  }
}

/// Cue 要先问你的几类事（唯一定义，Cue 的提示词与工具说明照它写）：收不回或越出它职责的事。只有这几类能写带选项的"等你"
/// （`CueStore.addCueMessage` 的 `ask`）；调研方案、设计取舍、实现路线、步骤与整件事算不算做完，Cue 按你的规矩与最佳实践自己定，做完告诉你。
/// 选项也由这里给（`choices`），Cue 不能自拟"照这个做 / 我再看看"这类确认；别的想法（不同意、选别的方案、补一句条件）他在 Cue 页底下直接说，
/// 卡随之收起（`CueQuestionEnd`）。
/// 给人看的只有 `name`（选项、设置里的"不用先问"）与 `why`；`definition` 只给 Cue 看。
public enum CueAsk: String, CaseIterable, Sendable {
  case push, merge, release, delete, outside, budget, rule

  /// 这类事给人看的叫法（"以后推送代码都不用问"、设置里的"不用先问"）；规矩那一类不出现在这两处。
  /// 范围要与 `definition` 一样大：选项照它写，选了放行的是整类。
  public var name: String {
    switch self {
    case .push: "推送代码"
    case .merge: "合并进共享分支"
    case .release: "发布或部署"
    case .delete: "删除文件、分支或数据"
    case .outside: "动项目外的东西"
    case .budget: "超出预算"
    case .rule: "你的规矩要先问的事"
    }
  }

  /// 这类事的确切范围，只给 Cue 看（系统提示与工具说明）。
  public var definition: String {
    switch self {
    case .push: "推送到远端"
    case .merge: "合并到共享分支"
    case .release: "发布或部署"
    case .delete: "删除文件、分支或数据"
    case .outside: "动项目以外的东西"
    case .budget: "超出预算"
    case .rule: "他的规矩明确要先问的事，或要违反、改动他的规矩"
    }
  }

  /// 第一项（主按钮）：允许这一次。
  public static let once = "可以"

  /// 提问的第二项：选了它，这类事以后在 `project`（关联任务所在项目的名字）里不再问，nil 是所有项目里都不再问；
  /// `CueStore.endCueQuestion` 按提问存的范围记进允许清单（`CueProfile.allows`）。规矩那一类没有这一项：一律放行等于没有规矩。
  public func always(in project: String?) -> String? {
    guard self != .rule else { return nil }
    return project.map { "以后「\($0)」里\(name)不用问" } ?? "以后\(name)都不用问"
  }

  /// 所有项目里都不用问那一项；没有它的（规矩那一类）不能记进允许清单。
  public var always: String? { always(in: nil) }

  /// 提问的选项（写入时定下、照存，之前写下的照旧显示当时的字）：可以，与"以后……不用问"（范围同上）。
  public func choices(in project: String?) -> [String] { [Self.once] + (always(in: project).map { [$0] } ?? []) }
}

/// Cue 的一次提问问的是什么（`CueStore.addCueMessage`）：哪一类、要做的动作，规矩那一类还有是哪条规矩；要你看的图在消息上（`CueMessage.shots`）。
/// 动作、规矩与每张图看什么是 Cue 写的短语，卡片、侧栏与菜单栏的摘要、小组件、本机与手机通知都只露这些，不露 Cue 的原话。
public struct CueAsking: Equatable, Sendable {
  public let ask: CueAsk
  /// 要做的动作（"推送 scheduler 的重连修复"）。
  public let action: String
  /// 规矩那一类依据的规矩（"改数据库结构前先问我"）；别的类没有。
  public let rule: String?

  /// 动作与规矩各至多这么多字。
  public static let phraseLimit = 30

  /// Cue 提问时给的：动作必填，规矩那一类还要写规矩；都是一行、不超过 `phraseLimit` 字，不合要求抛 `phrase`。
  public init(_ ask: CueAsk, action: String?, rule: String? = nil) throws {
    self.ask = ask
    self.action = try Self.phrase(action, "带 ask 要写 doing", "要做的动作，如“推送 scheduler 的重连修复”", limit: Self.phraseLimit)
    self.rule = ask == .rule ? try Self.phrase(rule, "带 ask 要写 rule", "依据的规矩，照他的原话，如“改数据库结构前先问我”", limit: Self.phraseLimit) : nil
  }

  /// 照存下的读回（`CueMessage.asking`、通知服务扩展读的同步记录）：认不出类别（更新的版本写的）、没有动作短语（结构 56 之前写的，
  /// 或规矩那一类没写规矩）的不算，卡片、摘要与通知照普通的话写它的第一行，回答的引用也是这一行。
  package init?(stored ask: CueAsk?, action: String?, rule: String?) {
    guard let ask, let action, ask != .rule || rule != nil else { return nil }
    self.ask = ask
    self.action = action
    self.rule = rule
  }

  /// Cue 写的短语：去掉首尾空白与句末标点，一行、不空、不超过 `limit` 字，不合要求抛 `phrase`（`field` 是报错的开头）。
  fileprivate static func phrase(_ text: String?, _ field: String, _ hint: String, limit: Int) throws -> String {
    let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "。？?！!"))
    guard !trimmed.isEmpty, trimmed.count <= limit, !trimmed.contains(where: \.isNewline) else {
      throw CueStoreError.phrase(field: field, hint: hint, limit: limit)
    }
    return trimmed
  }

  /// 要你定什么（卡片第一句、摘要、通知同一句）。
  public var question: String {
    // 动作两头是字母或数字时与汉字之间空一格（"可以合并进 main 吗？"），同界面上中英文混排的写法
    func gap(_ character: Character?) -> String { character.map { $0.isASCII && ($0.isLetter || $0.isNumber) } == true ? " " : "" }
    return "可以\(gap(action.first))\(action)\(gap(action.last))吗？"
  }

  /// 规矩那一类为什么问你：引他的规矩原话（卡片与通知的第二句）。别的类没有：推送、删除这些收不回的地方他自己知道，卡上只留问句。
  public var why: String? { rule.map { "你说过「\($0)」。" } }
}

/// Cue 点名要你看的一张图（`CueMessage.shots`）：发到手机的哪一份（`PiPreview.id`）与看它的什么（Cue 写的一句）。写下就不再变；那一份不在了（会话的预览过期删掉）就不显示。
public struct CueShot: Codable, Hashable, Sendable {
  public let preview: UUID
  public let look: String

  /// 一条消息至多这么多张：只挑回答问题必须看的、证明结论的。
  public static let limit = 4
  /// 看什么至多这么多字。
  public static let lookLimit = 20

  public init(preview: UUID, look: String) {
    self.preview = preview
    self.look = look
  }

  /// Cue 点名的一组：至多 `limit` 张、不重复，每张一句看什么（一行、`lookLimit` 字以内）；多了或重复抛 `shots`，看什么不合要求抛 `phrase`。
  public static func checked(_ shots: [CueShot]) throws -> [CueShot] {
    guard shots.count <= limit, Set(shots.map(\.preview)).count == shots.count else { throw CueStoreError.shots(limit: limit) }
    return try shots.map {
      CueShot(preview: $0.preview, look: try CueAsking.phrase($0.look, "show 每张要写 look", "这张看什么，如“方案 1：大按钮占满一行”", limit: lookLimit))
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

  package init?(stored: String) {
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
/// "等你"的正文是要你定什么、规矩那一类引的规矩（`CueAsking`）、要看的图各看什么（`looks`），接选项，与卡片同源；其余（读不出 `CueAsking` 的提问也是）是 Cue 的原话
/// （去掉图片，行内的 Markdown 记号只留字，至多 `bodyLimit` 字）。
public enum CueAlert {
  public static let bodyLimit = 300

  public static func content(name: String?, text: String, asking: CueAsking?, choices: [String]?, looks: [String]) -> (title: String, body: String) {
    let body: String
    if let asking, let choices {
      let shots = looks.isEmpty ? [] : ["看图：" + looks.joined(separator: "；")]
      body = ([asking.question] + [asking.why].compactMap(\.self) + shots + [choices.joined(separator: " / ")]).joined(separator: "\n")
    } else {
      let plain = CueFormat.plainText(text)
      let words = (try? AttributedString(markdown: plain, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) }
      body = (words ?? plain).trimmingCharacters(in: .whitespacesAndNewlines).clipped(bodyLimit)
    }
    let name = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (name.isEmpty ? CueProfile.defaultName : name, body)
  }
}
