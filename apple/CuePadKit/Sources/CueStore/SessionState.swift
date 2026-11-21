import Foundation

public struct SessionState: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var sessionID: String
  public var hostID: String
  public var bootID: String?
  public internal(set) var runtimeUntil: Date?
  public internal(set) var offlineMac: String?
  public var title: String
  public var projectID: UUID?
  public var state: Open<WorkState>
  private var storedDetail: String?
  public var detail: String? {
    get { failure?.known == .truncated ? ChatNotice.truncated.label : storedDetail }
    set { storedDetail = newValue }
  }
  public var failure: Open<FailureKind>?

  public var usageURL: URL? { failure?.known == .quota ? model?.account?.usageURL(provider: model?.key.provider ?? "") : nil }
  public var folder: String?
  public var lastPrompt: String?
  public var lastReply: String?
  public var pendingPrompt: String?
  public var pendingTools: ChatMessage.Tools?
  public var answeredAt: Date?
  public var question: Question?
  public var notify: AlertPush?
  public var stateSince: Date
  public var busySince: Date?
  public var turnStartedAt: Date?
  public var turnOpener: TurnOpener?
  public var createdAt: Date
  public var modifiedAt: Date
  public var launchToken: String?
  public var hosted: Bool
  public internal(set) var createdForTaskID: UUID?
  public internal(set) var restoredAt: Date?
  public var subagents: [SubagentState]
  public var model: ModelOption?
  public var thinking: Open<ThinkingLevel>?
  public var fast: Bool?
  public var context: ContextUsage?
  public var agent: Open<AgentKind>
  public var catalogID: UUID?

  public init(
    id: UUID, sessionID: String, hostID: String, title: String, projectID: UUID?, state: Open<WorkState>, detail: String?,
    folder: String?, lastPrompt: String?, lastReply: String?, question: Question?, notify: AlertPush?, stateSince: Date,
    busySince: Date?, createdAt: Date, modifiedAt: Date, launchToken: String? = nil, hosted: Bool = false,
    subagents: [SubagentState] = [], pendingPrompt: String? = nil, pendingTools: ChatMessage.Tools? = nil, model: ModelOption? = nil,
    thinking: Open<ThinkingLevel>? = nil, fast: Bool? = nil, context: ContextUsage? = nil, agent: Open<AgentKind> = .known(.pi), catalogID: UUID? = nil,
    turnStartedAt: Date? = nil, turnOpener: TurnOpener? = nil, answeredAt: Date? = nil, failure: Open<FailureKind>? = nil, bootID: String? = nil,
    runtimeUntil: Date? = nil, createdForTaskID: UUID? = nil, restoredAt: Date? = nil
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
    self.restoredAt = restoredAt
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
    self.turnOpener = turnOpener
    self.answeredAt = answeredAt
    self.failure = failure
  }

  public var capabilities: AgentCapabilities { agent.known.map { .of($0, model: model) } ?? [] }

  public var endsWithTask: Bool { createdForTaskID != nil && restoredAt == nil && canEnd }

  public var canEnd: Bool { state != .known(.ended) }

  public var canStop: Bool {
    runtimeState.known?.isTurnRunning == true && state != .known(.waitingForUser)
  }

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

  public var answered: Bool {
    guard let turnStartedAt, let answeredAt else { return false }
    return answeredAt >= turnStartedAt
  }

  public func answered(since requestedAt: Date) -> Bool {
    guard let turnStartedAt else { return false }
    return turnStartedAt > requestedAt && answered
  }

  public static let detailSeparator = " · "

  public func waitsForCue(_ cue: CueDuty?) -> Bool { cue.map { !$0.leftToYou(self) } == true && answerableQuestion != nil }

  public func asksYou(_ cue: CueDuty?) -> Bool { runtimeState == .known(.waitingForUser) && !waitsForCue(cue) }

  public func awaitsReply(_ cue: CueDuty?) -> Bool { runtimeState != .unknown("unconfirmed") && state != .known(.waitingForUser) && cue?.leftToYou(self) == true }

  public static func recordID(sessionID: String) -> UUID { DeterministicID.uuid("pi-session/\(sessionID)") }
}

extension SessionState {
  public var shortID: String { String(sessionID.prefix(8)) }
}

extension SessionState: Record, SyncedColumns {
  static let table = Table.piSessionStates
  static let recapColumns: Set<String> = ["lastPrompt", "lastReply", "pendingPrompt", "pendingTools", "answeredAt"]
  static let fields: [Field] = [
    .plain("id"), .plain("sessionID"), .plain("hostID"), .encrypted("title"), .plain("projectID"), .plain("state"),
    .encrypted("detail"), .plain("stateSince"), .plain("createdAt"), .plain("modifiedAt"), .plain("notify"), .encrypted("folder"),
    .encrypted("lastPrompt"), .encrypted("lastReply"), .encrypted("question"), .plain("busySince"), .encrypted("launchToken"),
    .plain("hosted"), .encrypted("subagents"), .encrypted("pendingPrompt"), .encrypted("model"), .encrypted("thinking"),
    .encrypted("context"), .plain("agent"), .plain("catalogID"), .encrypted("pendingTools"), .plain("turnStartedAt"),
    .plain("answeredAt"), .plain("failure"), .plain("bootID"), .encrypted("fast"), .plain("createdForTaskID"),
    .plain("turnDelivery"), .plain("turnByCue"), .plain("restoredAt"),
  ]
  var bindings: [any SQLBindable] {
    [id, sessionID, hostID, title, projectID, state.rawValue, detail, stateSince, createdAt, modifiedAt, notify?.rawValue, folder,
     lastPrompt, lastReply, question?.stored, busySince, launchToken, hosted ? Int64(1) : nil, JSONColumn.encodeList(subagents), pendingPrompt,
     model.map(JSONColumn.encode), thinking?.rawValue, context.map(JSONColumn.encode), agent.rawValue, catalogID, pendingTools?.stored,
     turnStartedAt, answeredAt, failure?.rawValue, bootID, fast.map { $0 ? Int64(1) : Int64(0) }, createdForTaskID,
     turnOpener?.delivery, turnOpener.map { $0.cue ? Int64(1) : Int64(0) }, restoredAt]
  }
  init(row: Row) {
    self.init(
      id: row.uuid(0), sessionID: row.text(1), hostID: row.text(2), title: row.text(3), projectID: row.uuidOrNil(4),
      state: Open(rawValue: row.text(5)), detail: row.textOrNil(6), folder: row.textOrNil(11),
      lastPrompt: row.textOrNil(12), lastReply: row.textOrNil(13), question: row.textOrNil(14).flatMap(Question.init(stored:)),
      notify: row.textOrNil(10).flatMap(AlertPush.init(rawValue:)), stateSince: row.date(7), busySince: row.dateOrNil(15), createdAt: row.date(8),
      modifiedAt: row.date(9), launchToken: row.textOrNil(16), hosted: row.intOrNil(17) == 1,
      subagents: JSONColumn.decodeList(SubagentState.self, from: row.textOrNil(18)),
      pendingPrompt: row.text(5) == WorkState.ended.rawValue ? nil : row.textOrNil(19),
      pendingTools: row.text(5) == WorkState.ended.rawValue ? nil : row.textOrNil(25).flatMap(ChatMessage.Tools.init(stored:)),
      model: JSONColumn.decode(ModelOption.self, from: row.textOrNil(20)), thinking: row.textOrNil(21).map(Open.init(rawValue:)), fast: row.intOrNil(30).map { $0 == 1 },
      context: JSONColumn.decode(ContextUsage.self, from: row.textOrNil(22)),
      agent: Open(rawValue: row.text(23)), catalogID: row.uuidOrNil(24), turnStartedAt: row.dateOrNil(26),
      turnOpener: row.uuidOrNil(32).map { TurnOpener(delivery: $0, cue: row.intOrNil(33) == 1) },
      answeredAt: row.dateOrNil(27), failure: row.textOrNil(28).map(Open.init(rawValue:)), bootID: row.textOrNil(29), createdForTaskID: row.uuidOrNil(31),
      restoredAt: row.dateOrNil(34))
  }
}

public struct TurnOpener: Equatable, Hashable, Sendable {
  public let delivery: UUID
  public let cue: Bool

  public init(delivery: UUID, cue: Bool) {
    self.delivery = delivery
    self.cue = cue
  }
}

extension SubagentState {
  public var isRunning: Bool { phase == .known(.running) }
}
