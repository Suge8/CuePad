import Foundation

/// 会话按状态分的范围：在线的（未结束）、已结束的（含历史）、全部；`current` 是此刻有事的——在线的，加上已结束但还有话发给它的
/// （在唤醒、没能送达；投送请求了结后不久就被清理，所以只有这几条），项目的"此刻"读它。
public enum PiSessionScope: Sendable, Equatable {
  case live, ended, all, current
}

/// 一台 Mac 上一个文件夹里跑过的 Agent 会话（`CueStore.sessionFolders`）：`sessionID` 与 `projectID` 是其中最近那个会话的。
public struct SessionFolder: Sendable, Equatable {
  public var hostID: String
  public var folder: String
  public var sessionID: String
  public var projectID: UUID?
  public var count: Int

  public init(hostID: String, folder: String, sessionID: String, projectID: UUID?, count: Int) {
    self.hostID = hostID
    self.folder = folder
    self.sessionID = sessionID
    self.projectID = projectID
    self.count = count
  }
}

/// 会话列表的一页（Mac 与手机共用的唯一查询，见 `CueStore.piSessionPage`）。条件之间是"且"。
/// 历史会话有几千条：界面只读需要的范围与页，不整表读。
public struct PiSessionQuery: Sendable, Equatable {
  public var scope: PiSessionScope
  /// 在会话名、文件夹名、最后的提问里找（不分大小写）；nil 或空白表示全部。
  public var text: String?
  /// 只要归入这个项目的；nil 表示不限。
  public var project: UUID?
  /// 只要带这个认领标识的（新会话认领用，精确取一条）。
  public var launchToken: String?
  /// 只要这一条记录（`PiSessionState.id`）。
  public var id: UUID?
  public var offset: Int
  /// 一页多少条；`Int.max` 表示不分页（只用于本就不多的范围，如在线的）。
  public var limit: Int

  public init(
    scope: PiSessionScope = .all, text: String? = nil, project: UUID? = nil, launchToken: String? = nil, id: UUID? = nil,
    offset: Int = 0, limit: Int = 50
  ) {
    self.scope = scope
    self.text = text
    self.project = project
    self.launchToken = launchToken
    self.id = id
    self.offset = offset
    self.limit = limit
  }

  /// 全部在线会话（数量少，不分页）。
  public static let live = PiSessionQuery(scope: .live, limit: .max)
  /// 此刻有事的会话（在线的与还有话发给它的已结束会话，数量少，不分页）。
  public static let current = PiSessionQuery(scope: .current, limit: .max)
}

/// 列表里的一个会话、它所属的项目（没有绑定项目或项目已删为 nil；文件夹名在 `state.folder`），
/// 以及发给它的最近一条投送请求（界面据此在 Mac 吸收它之前就显示"发送中"等）。
public struct PiSessionListItem: Identifiable, Sendable, Equatable {
  public var state: PiSessionState
  public var project: Project?
  public var delivery: DeliveryRequest?
  /// 发给它的最近一条改名请求（带名字的配置请求）：改名在路上、没改成都由它推出。
  public var rename: DeliveryRequest?
  /// 发给它、没能送达的话有几句（说话的方式里失败、还没重发或移除的）：会话行的标记与会话页顶栏的"N 句没送到"同读这个数。
  public var undelivered: Int
  /// 绑着它的任务由 Cue 跟进（`cueFollowedSessions()`）：歇下时该看的是 Cue，不催你。
  public var cueFollows: Bool
  public var id: UUID { state.id }

  public init(
    state: PiSessionState, project: Project? = nil, delivery: DeliveryRequest? = nil, rename: DeliveryRequest? = nil, undelivered: Int = 0,
    cueFollows: Bool = false
  ) {
    self.state = state
    self.project = project
    self.delivery = delivery
    self.rename = rename
    self.undelivered = undelivered
    self.cueFollows = cueFollows
  }
}

/// 一页会话与符合条件的总数。顺序：未结束的在前，各自按进入当前状态的时间从新到旧。
public struct PiSessionPage: Sendable, Equatable {
  public var items: [PiSessionListItem]
  public var total: Int
}

/// 一个 Pi 会话的同步记录，Mac 写、手机与 Mac 的界面都只读它：每个 Pi 会话一条，记录 id 由 Pi 自己的会话 id 算出
/// （会话文件头里的 id，Pi 重启、恢复会话后不变），所以在线与历史是同一条记录的不同状态（历史即 `ended`）。
/// 说过话（有会话文件）的会话才进历史；托管的会话闲置退出不进历史。
/// Mac 上在线会话的状态来自 Pi 桥，历史来自本机的会话文件索引；会话文件被删时才删记录。完整路径不同步，只有文件夹名与项目。
/// 每个会话都属于一个任务叶子，不经任务开的由写它的 Mac 建同名任务挂上（`CueStore+SessionTasks`）。
public struct PiSessionState: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var sessionID: String
  /// 写入它的那台 Mac。
  public var hostID: String
  public var title: String
  public var projectID: UUID?
  public var state: Open<PiWorkState>
  /// 工具名、等待确认的问题、错误信息等。
  public var detail: String?
  /// 工作目录的最后一段（文件夹名），不含完整路径；手机据此在没有绑定项目时写出会话"在哪"。旧版本写的记录没有。
  public var folder: String?
  /// 摘要，见 `PiRecap`（同名字段）；`question` 是 Pi 此刻弹出、等你回答的对话框。旧版本写的记录没有。
  public var lastPrompt: String?
  public var lastReply: String?
  public var pendingPrompt: String?
  public var question: PiQuestion?
  /// 这次写入是否要通知手机；见 `PiAlert`。
  public var notify: Open<PiAlert>?
  /// 计时基准，见 `PiTimes`（同名字段）。界面：工作中"已运行"自 `busySince`，等你确认"已等"自 `stateSince`，其余"多久前"自 `stateSince`。
  public var stateSince: Date
  /// 旧版本写的记录没有。
  public var busySince: Date?
  public var createdAt: Date
  public var modifiedAt: Date
  /// 由 CuePad 发起的新会话（投送方式 `start`）带着发起方生成的标识（`PiLaunch.start` 的 `token`），
  /// 发起方据此等到并打开"自己开的那个"会话。其余会话为 nil。
  public var launchToken: String?
  /// Mac 在后台替你托管着它（没有终端界面；给已结束的会话发消息、开新会话时由 Mac 自动启动）。这样的会话没有终端可跳。
  /// 托管的进程闲置退出后记录留着（歇着，`hosted` 仍为真）：它仍在"现在"，发话时 Mac 把它唤醒——"托管且进程不在"就是这样表达的。
  public var hosted: Bool
  /// 会话里的子代理（FireCode 等在同一进程里开的子会话），一行一个。
  public var subagents: [PiSubagentState]
  /// 会话当前的模型与思考强度、可以换成的模型（Pi 桥上报；已结束的会话留着最后的模型与强度，可选列表清空）。旧版本写的记录没有。
  public var model: PiModelOption?
  public var thinking: Open<PiThinkingLevel>?
  public var models: [PiModelOption]
  /// 上下文余量（Pi 桥上报；已结束的会话留着最后一次的值）与此刻能用的斜杠命令（已结束的会话清空）。旧版本写的记录没有。
  public var context: PiContextUsage?
  public var commands: [PiSlashCommand]
  /// 哪个 Agent 的会话。旧版本写的记录没有，是 Pi。
  public var agent: Open<AgentKind>

  /// 公开给 Mac 端：把桥上的实时会话也写成这种形状，交给同一个近况界面。
  public init(
    id: UUID, sessionID: String, hostID: String, title: String, projectID: UUID?, state: Open<PiWorkState>, detail: String?,
    folder: String?, lastPrompt: String?, lastReply: String?, question: PiQuestion?, notify: Open<PiAlert>?, stateSince: Date,
    busySince: Date?, createdAt: Date, modifiedAt: Date, launchToken: String? = nil, hosted: Bool = false,
    subagents: [PiSubagentState] = [], pendingPrompt: String? = nil, model: PiModelOption? = nil,
    thinking: Open<PiThinkingLevel>? = nil, models: [PiModelOption] = [], context: PiContextUsage? = nil,
    commands: [PiSlashCommand] = [], agent: Open<AgentKind> = .known(.pi)
  ) {
    self.id = id
    self.sessionID = sessionID
    self.hostID = hostID
    self.title = title
    self.projectID = projectID
    self.state = state
    self.detail = detail
    self.folder = folder
    self.lastPrompt = lastPrompt
    self.lastReply = lastReply
    self.question = question
    self.notify = notify
    self.stateSince = stateSince
    self.busySince = busySince
    self.createdAt = createdAt
    self.modifiedAt = modifiedAt
    self.launchToken = launchToken
    self.hosted = hosted
    self.subagents = subagents
    self.pendingPrompt = pendingPrompt
    self.model = model
    self.thinking = thinking
    self.models = models
    self.context = context
    self.commands = commands
    self.agent = agent
  }

  /// 从 CuePad 能对它做什么（规则见 `AgentCapabilities.of`）；本版本不认识的 Agent 只能发文字。
  public var capabilities: AgentCapabilities { agent.known.map { .of($0, hosted: hosted) } ?? [] }

  // 下面几条是界面与 Cue 共用的唯一一份：做不到的操作界面上不露出，Cue 要做时报错。

  /// 此刻可用的发送方式，第一个是默认：正在跑一轮时直接发送会被拒绝，只能等它做完再说（默认，不打断）或马上说（次级，
  /// 只给做得到的会话，见 `AgentCapabilities.steer`）。已结束的会话也能直接发送：Mac 会在后台把它恢复起来再送达。
  public var deliveryModes: [DeliveryMode] {
    guard state.known?.isTurnRunning == true else { return [.send] }
    return capabilities.contains(.steer) ? [.followUp, .steer] : [.followUp]
  }

  /// 能结束：做得到，在线，且读得到（旧版扩展的会话收不到结束命令，要在终端里退出 Pi）。
  public var canEnd: Bool {
    capabilities.contains(.end) && state != .known(.ended) && state != .known(.incompatible)
  }

  /// 能停止这一轮：做得到，且指挥官自己在跑一轮、没在等你时；等你确认时它在等你答（停止会让人以为把问题也撤了），
  /// 等子代理时这一轮已经歇下，都没有可停的。
  public var canStop: Bool {
    capabilities.contains(.abort) && state.known?.isTurnRunning == true && state != .known(.waitingForUser)
  }

  /// 等你确认、且能从 CuePad 作答的问题（问题本身可答，这个会话也做得到）；其余只能在 Agent 那边答。
  public var answerableQuestion: PiQuestion? {
    guard state == .known(.waitingForUser), capabilities.contains(.answer), let question, question.isAnswerable else { return nil }
    return question
  }

  /// 记录上的摘要（对话的投影）。
  public var recap: PiRecap { PiRecap(lastPrompt: lastPrompt, lastReply: lastReply, pendingPrompt: pendingPrompt) }

  /// `detail` 里工具名与调用目标之间的分隔（Mac 写、手机读：`PiProgress` 据此拆开）。
  public static let detailSeparator = " · "

  /// 会话在等回答（弹了问题）。算不算"等你"还要看是不是由 Cue 跟进：见 `asksYou(cueFollows:)`。
  public var waitsForYou: Bool { state == .known(.waitingForUser) }

  /// "等你"里会话那一半的唯一规则：在等回答，且不由 Cue 跟进（Cue 跟进的由 Cue 去答或转问你）。"等你 N"、Dock 角标、
  /// "等你"的提示（Mac 的通知、手机的前台横幅与锁屏推送标志，`PiAlert.reaches`）都只认它。
  public func asksYou(cueFollows: Bool) -> Bool { waitsForYou && !cueFollows }

  /// 一个 Pi 会话对应的记录 id（每个会话一条，任何设备上算出来都一样）。
  public static func recordID(sessionID: String) -> UUID { DeterministicID.uuid("pi-session/\(sessionID)") }
}

extension PiSessionState: Record {
  static let table = Table.piSessionStates
  /// 对话的投影（见 `PiRecap`），只由 `writePiTranscript` 写
  static let recapColumns: Set<String> = ["lastPrompt", "lastReply", "pendingPrompt"]
  static let columns = [
    "id", "sessionID", "hostID", "title", "projectID", "state", "detail", "stateSince", "createdAt", "modifiedAt", "notify", "folder",
    "lastPrompt", "lastReply", "question", "busySince", "launchToken", "hosted", "subagents", "pendingPrompt",
    "model", "thinking", "models", "context", "commands", "agent",
  ]
  var bindings: [any SQLBindable] {
    [id, sessionID, hostID, title, projectID, state.rawValue, detail, stateSince, createdAt, modifiedAt, notify?.rawValue, folder,
     lastPrompt, lastReply, question?.stored, busySince, launchToken, hosted ? Int64(1) : nil, JSONColumn.encodeList(subagents), pendingPrompt,
     model.map(JSONColumn.encode), thinking?.rawValue, JSONColumn.encodeList(models), context.map(JSONColumn.encode),
     JSONColumn.encodeList(commands), agent.rawValue]
  }
  init(row: Row) {
    self.init(
      id: row.uuid(0), sessionID: row.text(1), hostID: row.text(2), title: row.text(3), projectID: row.uuidOrNil(4),
      state: Open(rawValue: row.text(5)), detail: row.textOrNil(6), folder: row.textOrNil(11),
      lastPrompt: row.textOrNil(12), lastReply: row.textOrNil(13), question: row.textOrNil(14).flatMap(PiQuestion.init(stored:)),
      notify: row.textOrNil(10).map(Open.init(rawValue:)), stateSince: row.date(7), busySince: row.dateOrNil(15), createdAt: row.date(8),
      modifiedAt: row.date(9), launchToken: row.textOrNil(16), hosted: row.intOrNil(17) == 1,
      subagents: JSONColumn.decodeList(PiSubagentState.self, from: row.textOrNil(18)),
      // 列里是会话文件的投影原样（最后一句可能是上次中途退出、没等到回答的）；已结束的会话没有正在处理的提问，
      // 会话重新连上时又是它——不必等文件再追加
      pendingPrompt: row.text(5) == PiWorkState.ended.rawValue ? nil : row.textOrNil(19),
      model: JSONColumn.decode(PiModelOption.self, from: row.textOrNil(20)), thinking: row.textOrNil(21).map(Open.init(rawValue:)),
      models: JSONColumn.decodeList(PiModelOption.self, from: row.textOrNil(22)),
      context: JSONColumn.decode(PiContextUsage.self, from: row.textOrNil(23)),
      commands: JSONColumn.decodeList(PiSlashCommand.self, from: row.textOrNil(24)),
      agent: row.textOrNil(25).map(Open.init(rawValue:)) ?? .known(.pi))
  }
}
