import Foundation

/// Mac 写，手机与 Mac 的界面都只读它。记录 id 由 Pi 自己的会话 id 算出（Pi 重启、恢复会话后不变），所以在线与历史是同一条记录的不同状态。
/// 说过话（有会话文件）的会话才进历史；会话文件被删时才删记录。
/// 不经任务开的会话（“新会话”、接着的历史会话）不绑任务，要为它的结果负责时再绑（`CueStore.bindSession`）。
public struct SessionState: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var sessionID: String
  public var hostID: String
  /// 见证这条记录此刻状态的那次系统启动：真实报告、本机收尾（进程没了）或启动对账时写；历史回填不写。
  public var bootID: String?
  /// Store 读取时派生，不持久化；没有证明不等于空闲。
  public internal(set) var runtimeUntil: Date?
  /// 没确认是因为所在的 Mac 此刻不在线时是那台的名字（`MacAgents.shownName`）；Store 读取时派生，不持久化。
  public internal(set) var offlineMac: String?
  public var title: String
  public var projectID: UUID?
  public var state: Open<WorkState>
  private var storedDetail: String?
  public var detail: String? {
    get { failure?.known == .truncated ? ChatNotice.truncated.label : storedDetail }
    set { storedDetail = newValue }
  }
  /// 出错块与看板上写的原因只读它。旧版本写的记录没有，按其余处理。
  public var failure: Open<FailureKind>?

  public var usageURL: URL? { failure?.known == .quota ? model?.account?.usageURL(provider: model?.key.provider ?? "") : nil }
  /// 工作目录的最后一段（文件夹名），不含完整路径。旧版本写的记录没有。
  public var folder: String?
  /// 旧版本写的记录没有。
  public var lastPrompt: String?
  public var lastReply: String?
  public var pendingPrompt: String?
  public var pendingTools: ChatMessage.Tools?
  public var answeredAt: Date?
  public var question: Question?
  /// 随那一次上传送出后清掉，远端带回来的不留。
  public var notify: AlertPush?
  public var stateSince: Date
  /// 旧版本写的记录没有。
  public var busySince: Date?
  /// 主会话最后一轮开始的时刻（你开的，或 Agent 自己为子代理的结果开的；等子代理到跟进轮之间 `busySince` 不变，这个要变）：
  /// 早于这一轮可能在会话文件里收尾的任何时刻（取法见 `SessionFacts.startTurn(at:)` 与 Pi 扩展的 `turnSince`）。还没开过一轮为 nil。
  public var turnStartedAt: Date?
  public var createdAt: Date
  public var modifiedAt: Date
  /// 发起方生成的标识（`LaunchRequest` 的 `token`），发起方据此等到并打开“自己开的那个”会话；其余会话为 nil。
  public var launchToken: String?
  /// 这台 Mac（`hostID`）托管过它：CuePad 在后台开的或接着的，结束后也留着（`CueStore.hostedSessionIDs` 靠它认）；在不在线只看 `state`。
  /// 没托管过的只是会话文件回填的历史。托管的进程闲置退出后是歇着：仍在“现在”，发话时 Mac 把它唤醒。
  public var hosted: Bool
  /// 创建此会话的任务；唯一生命周期来源，纯关联与后来的发送不改变它。未知来源不授权自动结束。
  public internal(set) var createdForTaskID: UUID?
  /// FireCode 等在同一进程里开的子会话。
  public var subagents: [SubagentState]
  /// 已结束的会话留着最后的值。旧版本写的记录没有。
  public var model: ModelOption?
  public var thinking: Open<ThinkingLevel>?
  public var fast: Bool?
  /// 已结束的会话留着最后一次的值。旧版本写的记录没有。
  public var context: ContextUsage?
  public var agent: Open<AgentKind>
  /// 同一目录里的会话共用；会话结束后也留着。
  public var catalogID: UUID?

  /// 公开给 Mac 端：把桥上的实时会话也写成这种形状，交给同一个近况界面。
  public init(
    id: UUID, sessionID: String, hostID: String, title: String, projectID: UUID?, state: Open<WorkState>, detail: String?,
    folder: String?, lastPrompt: String?, lastReply: String?, question: Question?, notify: AlertPush?, stateSince: Date,
    busySince: Date?, createdAt: Date, modifiedAt: Date, launchToken: String? = nil, hosted: Bool = false,
    subagents: [SubagentState] = [], pendingPrompt: String? = nil, pendingTools: ChatMessage.Tools? = nil, model: ModelOption? = nil,
    thinking: Open<ThinkingLevel>? = nil, fast: Bool? = nil, context: ContextUsage? = nil, agent: Open<AgentKind> = .known(.pi), catalogID: UUID? = nil,
    turnStartedAt: Date? = nil, answeredAt: Date? = nil, failure: Open<FailureKind>? = nil, bootID: String? = nil, runtimeUntil: Date? = nil, createdForTaskID: UUID? = nil
  ) {
    self.id = id
    self.sessionID = sessionID
    self.hostID = hostID
    self.bootID = bootID
    self.runtimeUntil = runtimeUntil
    self.title = title
    self.projectID = projectID
    self.state = state
    self.storedDetail = detail
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
    self.createdForTaskID = createdForTaskID
    self.subagents = subagents
    self.pendingPrompt = pendingPrompt
    self.pendingTools = pendingTools
    self.model = model
    self.thinking = thinking
    self.fast = fast
    self.context = context
    self.agent = agent
    self.catalogID = catalogID
    self.turnStartedAt = turnStartedAt
    self.answeredAt = answeredAt
    self.failure = failure
  }

  /// 本版本不认识的 Agent（更新版本的 Mac 上新接的一家）一样也不认。
  public var capabilities: AgentCapabilities { agent.known.map { .of($0, model: model) } ?? [] }

  // 下面几条是界面与 Cue 共用的唯一一份：做不到的操作界面上不露出，Cue 要做时报错。

  /// 只结束为任务创建的；完成前的确认照这个说（App 的 `agentBusyDialog`）。
  public var endsWithTask: Bool { createdForTaskID != nil && canEnd }

  public var canEnd: Bool { state != .known(.ended) }

  /// 等你确认时不算：它在等你答，停止会让人以为把问题也撤了；等子代理时这一轮已经歇下，没有可停的。
  public var canStop: Bool {
    runtimeState.known?.isTurnRunning == true && state != .known(.waitingForUser)
  }

  /// 原样重跑出错的那一轮，不在对话里多一句话；这一类错重跑有用才行（`FailureKind.retries`，没记种类的按其余）。
  public var canRetry: Bool {
    state == .known(.error) && capabilities.contains(.retry) && failure?.known?.retries != false
  }

  public var answerableQuestion: Question? {
    guard runtimeState == .known(.waitingForUser), let question, question.isAnswerable else { return nil }
    return question
  }

  public var recap: Recap {
    Recap(lastPrompt: lastPrompt, lastReply: lastReply, pendingPrompt: pendingPrompt, pendingTools: pendingTools, answeredAt: answeredAt)
  }

  /// 状态由 Agent 报、问答由读会话文件写，两路先后不定：歇下要等这里为真才是 Cue 的变化（`CueStore.cueChanges`），你开的、Agent 自己开的（子代理交回、补开的空输入）同一条规则。
  /// 一轮都没开过（刚开出来就歇着）不算。
  public var answered: Bool {
    guard let turnStartedAt, let answeredAt else { return false }
    return answeredAt >= turnStartedAt
  }

  /// ACK 的落库可能比回答更晚，不能因此继续遮住终态。
  public func answered(since requestedAt: Date) -> Bool {
    guard let turnStartedAt else { return false }
    return turnStartedAt > requestedAt && answered
  }

  /// `detail` 里工具名与调用目标之间的分隔（Mac 写、手机读：`SessionProgress` 据此拆开）。
  public static let detailSeparator = " · "

  /// 等的是 Cue：它去答或转问你。
  public func waitsForCue(_ cue: CueDuty?) -> Bool { cue.map { !$0.leftToYou(self) } == true && answerableQuestion != nil }

  /// 拍板里会话那一半的唯一规则。拍板卡、“等你确认”的提示（Mac 的通知、手机的前台横幅与锁屏推送标志，`CueStore.reaches`）都只认它。
  /// 歇着的不算，留给你回的是待回复（`awaitsReply`），两种合起来是等你（`CueTally`）。
  public func asksYou(_ cue: CueDuty?) -> Bool { runtimeState == .known(.waitingForUser) && !waitsForCue(cue) }

  /// 待回复的唯一规则。会话行的“待回复”（出错的照样显示出错）、会话条、名牌、看板等你列里的待回复与待回复的提示（`CueStore.sessionsAwaitingReply`、`reaches`）都只认它。
  public func awaitsReply(_ cue: CueDuty?) -> Bool { runtimeState != .unknown("unconfirmed") && state != .known(.waitingForUser) && cue?.leftToYou(self) == true }

  /// 任何设备上算出来都一样。
  public static func recordID(sessionID: String) -> UUID { DeterministicID.uuid("pi-session/\(sessionID)") }
}

extension SessionState {
  /// 给 Cue 看的会话短 id：会话 id 的前 8 位（Cue 的工具接受至少 4 位的前缀）。
  public var shortID: String { String(sessionID.prefix(8)) }
}

extension SessionState: Record {
  static let table = Table.piSessionStates
  /// 只由 `writeTranscript` 写
  static let recapColumns: Set<String> = ["lastPrompt", "lastReply", "pendingPrompt", "pendingTools", "answeredAt"]
  static let columns = [
    "id", "sessionID", "hostID", "title", "projectID", "state", "detail", "stateSince", "createdAt", "modifiedAt", "notify", "folder",
    "lastPrompt", "lastReply", "question", "busySince", "launchToken", "hosted", "subagents", "pendingPrompt",
    "model", "thinking", "context", "agent", "catalogID", "pendingTools", "turnStartedAt", "answeredAt", "failure", "bootID", "fast", "createdForTaskID",
  ]
  var bindings: [any SQLBindable] {
    [id, sessionID, hostID, title, projectID, state.rawValue, detail, stateSince, createdAt, modifiedAt, notify?.rawValue, folder,
     lastPrompt, lastReply, question?.stored, busySince, launchToken, hosted ? Int64(1) : nil, JSONColumn.encodeList(subagents), pendingPrompt,
     model.map(JSONColumn.encode), thinking?.rawValue, context.map(JSONColumn.encode), agent.rawValue, catalogID, pendingTools?.stored,
     turnStartedAt, answeredAt, failure?.rawValue, bootID, fast.map { $0 ? Int64(1) : Int64(0) }, createdForTaskID]
  }
  init(row: Row) {
    self.init(
      id: row.uuid(0), sessionID: row.text(1), hostID: row.text(2), title: row.text(3), projectID: row.uuidOrNil(4),
      state: Open(rawValue: row.text(5)), detail: row.textOrNil(6), folder: row.textOrNil(11),
      lastPrompt: row.textOrNil(12), lastReply: row.textOrNil(13), question: row.textOrNil(14).flatMap(Question.init(stored:)),
      notify: row.textOrNil(10).flatMap(AlertPush.init(rawValue:)), stateSince: row.date(7), busySince: row.dateOrNil(15), createdAt: row.date(8),
      modifiedAt: row.date(9), launchToken: row.textOrNil(16), hosted: row.intOrNil(17) == 1,
      subagents: JSONColumn.decodeList(SubagentState.self, from: row.textOrNil(18)),
      // 列里是会话文件的投影原样（最后一句可能是上次中途退出、没等到回答的）；已结束的会话没有正在处理的提问，
      // 会话重新连上时又是它——不必等文件再追加
      pendingPrompt: row.text(5) == WorkState.ended.rawValue ? nil : row.textOrNil(19),
      pendingTools: row.text(5) == WorkState.ended.rawValue ? nil : row.textOrNil(25).flatMap(ChatMessage.Tools.init(stored:)),
      model: JSONColumn.decode(ModelOption.self, from: row.textOrNil(20)), thinking: row.textOrNil(21).map(Open.init(rawValue:)), fast: row.intOrNil(30).map { $0 == 1 },
      context: JSONColumn.decode(ContextUsage.self, from: row.textOrNil(22)),
      agent: Open(rawValue: row.text(23)), catalogID: row.uuidOrNil(24), turnStartedAt: row.dateOrNil(26),
      answeredAt: row.dateOrNil(27), failure: row.textOrNil(28).map(Open.init(rawValue:)), bootID: row.textOrNil(29), createdForTaskID: row.uuidOrNil(31))
  }
}

extension SubagentState {
  /// 只此一个定义，各处都读它。在被审查的不算：审查期间它自己是闲的，等的是审查它的那位。
  public var isRunning: Bool { phase == .known(.running) }
}
