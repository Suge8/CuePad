import CueText
import Foundation

// 任务交给会话、跟进与看板：界面与 Cue（经 MCP）共用这一份规则。`cue` 为真的写入标明来自 Cue（`DeliveryOrigin`）。

/// 提示词交到哪（`CueStore.handOffPlan`）：界面（Mac 的发给 Agent、手机发给 Agent 的默认目标）与 Cue 的 `startLeaf` 共用这一份规则。
public struct HandOffPlan: Equatable, Sendable {
  public enum Destination: Equatable, Sendable {
    /// 叶子绑着的会话：Pi 的会话 id、显示名、由哪台 Mac 执行（会话所在的那台；记录还没到时是发起的这台，手机上为 nil）。
    case session(id: String, title: String, host: String?)
    /// 在项目绑定的文件夹开新会话，由绑了文件夹的那台 Mac 执行（发起的这台绑了就是它）。
    case launch(project: UUID, host: String)
    /// 项目哪台 Mac 都没绑文件夹，开不了会话。
    case noFolder(project: UUID, projectName: String)
    /// 未分类的任务没有文件夹，开不了会话。
    case unfiled
  }

  /// 交给会话的叶子。
  public var leaf: UUID
  public var destination: Destination
  /// 从这件事开的会话叫什么（`CueStore.sessionName(forCard:)`，`requestLaunch` 起名用的同一条规则）：叶子的标题；没有标题为 nil。
  public var name: String?
}

/// 对会话说话的时机（`CueStore.sayToLeaf`）：会话正忙时马上说（插进这一轮）还是等它做完再说；歇着时两种都是直接说。
public enum SayTiming: Sendable {
  case now, after
}

/// Cue 眼里的一个项目（`CueStore.cueProjects`）。
public struct CueProject: Identifiable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  /// 绑了文件夹（开得了会话）。
  public var hasFolder: Bool

  public init(id: UUID, name: String, hasFolder: Bool) {
    self.id = id
    self.name = name
    self.hasFolder = hasFolder
  }
}

/// 看板上的一件事：Cue 跟进的一个顶层任务。
public struct CueBoardItem: Identifiable, Equatable, Sendable {
  public var task: Card
  /// 步骤完成了几个；没有步骤为 nil。
  public var progress: TaskProgress?
  /// 此刻在做的叶子：没有步骤是任务自己，否则第一个没完成的步骤；步骤都做完了是最后做完的那一步（近况取它的会话，不落回第一步）。
  public var leaf: Card
  /// 叶子的会话记录；还没开会话（或记录还没到）为 nil。
  public var session: PiSessionState?
  /// 正在为叶子开新会话（请求还没执行完，或开好了还没认领到）。
  public var launching: Bool
  /// 停在当前状态的起点：会话进入当前状态的时刻，没有会话时是开始做或设为任务的时刻。
  public var since: Date
  public var id: UUID { task.id }
}

/// 某时刻之后，Cue 跟进的事里的一处变化。
public struct CueChange: Equatable, Sendable {
  public enum Kind: String, Sendable, CaseIterable {
    /// 会话歇下（这一轮做完）
    case settled
    /// 会话在等回答
    case waitingForUser
    /// 会话出错，或 Cue 发起的请求（开工、说话、作答、停下、结束）没能执行（`detail` 是"动作：Mac 报的原因"；你发起的失败界面上看得见，不报）
    case failed
    /// 叶子或任务完成
    case done
    /// 你在会话里亲自说了话（在终端里打的）
    case youSpoke
    /// 你把这件事交给 Cue 跟进
    case joined
    /// 不再由 Cue 跟进：你接手了、删了、归档了等（`detail` 说明）；完成了的只报 `done`
    case left
  }

  public var kind: Kind
  /// 顶层任务的 id。
  public var taskID: UUID
  /// 顶层任务；已永久删除（只会是 `left`）为 nil。
  public var task: Card?
  /// 变化所在的叶子；任务本身的变化为 nil。
  public var leaf: Card?
  public var at: Date
  /// 提问、错误、你说的话、为什么不再跟进、哪个请求为什么没成。
  public var detail: String?
  /// 会话记录里已有的摘要：叶子的会话的；任务本身的变化取它最近有动静的那个会话的。
  public var recap: PiRecap?

  init(kind: Kind, taskID: UUID, task: Card?, leaf: Card? = nil, at: Date, detail: String? = nil, recap: PiRecap? = nil) {
    self.kind = kind
    self.taskID = taskID
    self.task = task
    self.leaf = leaf
    self.at = at
    self.detail = detail
    self.recap = recap
  }
}

/// 一件事的细节（Cue 的 peek）：叶子、各自的草稿、会话、最近几轮问答与预览。
public struct CueTaskDetail: Equatable, Sendable {
  public var task: Card
  public var progress: TaskProgress?
  public var leaves: [CueLeafDetail]
}

public struct CueLeafDetail: Equatable, Sendable {
  public var leaf: Card
  public var draft: Card?
  public var session: PiSessionState?
  /// 最近几轮问答（你说的与 Pi 的回答），从早到晚。
  public var recent: [PiChatMessage]
  public var previews: [PiPreview]
}

extension Card {
  /// 标题（`CueSummary` 的规则，唯一一处）：Cue 的工具、信封与界面都用它。空白的卡是空串（App 的 `title` 另给占位说法）。
  public var heading: String { CueSummary(body).title }
}

extension UUID {
  /// 给 Cue 与人看的短 id：小写的前 8 位（Cue 的工具接受至少 4 位的前缀）。
  public var shortID: String { String(uuidString.lowercased().prefix(8)) }
}

extension CueStore {
  // MARK: 交给会话

  /// 提示词交到哪：给叶子或它的提示词（叶子下的草稿）。叶子绑着会话就交给那个会话；没绑就在项目绑定的文件夹开一个以叶子标题命名的新会话
  /// （这台 Mac 绑了就在这台，否则别的 Mac 里按名字排第一台）。`host` 是发起的这台 Mac，手机为 nil。
  /// 不是叶子或叶子的提示词抛 `notATask` / `notALeaf`。
  public func handOffPlan(_ card: UUID, host: String?) throws -> HandOffPlan {
    guard let found = try find(Card.self, card) else { throw CueStoreError.notFound }
    let leaf = try requireLeaf(found.isTask ? card : found.parentID ?? card)
    return HandOffPlan(leaf: leaf.id, destination: try destination(of: leaf, host: host), name: try sessionName(forCard: leaf.id))
  }

  /// `fresh`：不管绑着的会话，照样在文件夹开新会话（Cue 的 `startLeaf`）。
  private func destination(of leaf: Card, host: String?, fresh: Bool = false) throws -> HandOffPlan.Destination {
    if !fresh, let sessionID = leaf.piSessionID {
      let session = try sessionTarget(of: leaf)
      return .session(id: sessionID, title: session.target.name, host: session.host(or: host))
    }
    guard let project = leaf.projectID else { return .unfiled }
    guard let launchHost = try launchHost(for: project, preferring: host) else {
      return .noFolder(project: project, projectName: try find(Project.self, project)?.name ?? "")
    }
    return .launch(project: project, host: launchHost)
  }

  /// Cue 开工：把叶子（没有步骤的任务）的草稿交到 `handOffPlan` 定下的地方。交给已有会话时会话正忙就等它做完再说；
  /// 开新会话时草稿作为第一句（没有草稿就只开会话）；送达后草稿用掉（`PromptConsumption`）。
  /// 叶子还没有会话、同一顶层任务的别的步骤绑着没结束的会话时，不开新会话：接着用那个（`continuableSession`），
  /// 叶子绑上它、草稿作为下一句发进去（没有草稿就只绑上，返回 nil）。`fresh` 为真时总是开新会话（叶子绑着的也换成新的：
  /// 上下文太长、要换 Agent，或那个会话换不了模型）。
  /// 已有会话却没有草稿抛 `alreadyStarted`，正在开会话抛 `launching`，开不了会话抛 `noFolder`。
  /// `agent` 缺省是 Pi，给了就只接着用这一家的会话；`agent`、`model` 与 `thinking` 只用于开新会话。
  public func startLeaf(
    _ leaf: UUID, agent: AgentKind? = nil, fresh: Bool = false, model: PiModelKey? = nil, thinking: PiThinkingLevel? = nil,
    host: String, cue: Bool = false
  ) throws -> DeliveryRequest? {
    var plan = try handOffPlan(leaf, host: host)
    if fresh { plan.destination = try destination(of: try requireLeaf(plan.leaf), host: host, fresh: true) }
    let draft = try draft(of: plan.leaf)
    let content = draft.map { CueFormat.readable(CueVariables.fill($0.body, values: $0.variableValues)) } ?? ""
    if !fresh, try requireLeaf(plan.leaf).piSessionID == nil, let session = try continuableSession(for: plan.leaf, agent: agent) {
      try linkCard(plan.leaf, toSession: session.sessionID)
      guard let draft else { return nil }
      return try say(content, to: try sessionTarget(of: try requireLeaf(plan.leaf)), when: .after, card: draft.id, host: host, cue: cue)
    }
    switch plan.destination {
    case .session:
      guard let draft else { throw CueStoreError.alreadyStarted(try requireLeaf(plan.leaf).heading) }
      return try say(content, to: try sessionTarget(of: try requireLeaf(plan.leaf)), when: .after, card: draft.id, host: host, cue: cue)
    case .launch(let project, let host):
      guard try launchingLeaves([plan.leaf]).isEmpty else { throw CueStoreError.launching(try requireLeaf(plan.leaf).heading) }
      let launch = PiLaunch(
        project: project, prompt: content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : content, token: UUID().uuidString,
        agent: agent ?? .pi, model: model, thinking: thinking)
      return try requestLaunch(launch, title: plan.name ?? "", on: host, card: draft?.id ?? plan.leaf, cue: cue)
    case .noFolder(_, let projectName): throw CueStoreError.noFolder(projectName)
    case .unfiled: throw CueStoreError.noFolder("")
    }
  }

  /// 同一顶层任务下别的步骤绑着、还没结束的会话里最近有动静的那个（`agent` 给了就只要这一家的）：下一步接着用它，上下文不丢。
  private func continuableSession(for leaf: UUID, agent: AgentKind?) throws -> PiSessionState? {
    let top = try topTask(of: leaf)
    guard top != leaf, let task = try find(Card.self, top) else { return nil }
    let sessions = try sessionStates(try leaves(of: task).compactMap(\.piSessionID))
    return sessions.values
      .filter { session in session.state != .known(.ended) && agent.map { session.agent == .known($0) } != false }
      .max { $0.stateSince < $1.stateSince }
  }

  /// 对叶子已有的会话说话。方式由会话此刻的状态定：歇着就直接说；正在跑一轮时 `now` 马上说、`after` 等它做完再说。
  /// 没有会话抛 `noSession`（正在开会话抛 `launching`）。
  /// 带 `config`（模型、思考强度）时先请会话换上（与界面换模型同一种请求），再说这句，两条按先后执行；
  /// 会话换不了模型（`AgentCapabilities.model`，记录没到也算不知道、不换）抛 `cannotChangeModel`，什么都不写。
  public func sayToLeaf(
    _ leaf: UUID, text: String, when: SayTiming, config: PiConfig? = nil, host: String, cue: Bool = false
  ) throws -> DeliveryRequest {
    let (card, session) = try requireSession(of: leaf)
    try requestConfig(config, of: card, in: session, host: host, cue: cue)
    return try say(text, to: session, when: when, card: card.id, host: host, cue: cue)
  }

  /// 说话、作答之前先请会话换上 `config`（与界面换模型同一种请求，执行器按先后执行）；换不了模型
  /// （`AgentCapabilities.model`，记录没到也算不知道、不换）抛 `cannotChangeModel`。调用方先做完别的检查：抛错时什么都没写。
  private func requestConfig(_ config: PiConfig?, of card: Card, in session: SessionTarget, host: String, cue: Bool) throws {
    guard let config else { return }
    guard session.state?.capabilities.contains(.model) == true else { throw CueStoreError.cannotChangeModel(card.heading) }
    try requestDelivery(config.stored, to: session.target, on: session.host(or: host), mode: .config, cue: cue)
  }

  /// 交给会话一句话，按会话此刻做得到的（与界面同一组规则，`PiSessionState.deliveryModes`、`AgentCapabilities.images`）：
  /// 正在跑一轮时 `now` 马上说（做不到就等它做完再说），收不了图片的只发文字。记录还没到时直接说、原样发。
  private func say(
    _ content: String, to session: SessionTarget, when: SayTiming, card: UUID, host: String, cue: Bool
  ) throws -> DeliveryRequest {
    let modes = session.state?.deliveryModes ?? [.send]
    let mode = when == .now && modes.contains(.steer) ? DeliveryMode.steer : modes[0]
    let content = session.state?.capabilities.contains(.images) == false ? CueFormat.withoutImages(content) : content
    return try requestDelivery(content, to: session.target, on: session.host(or: host), mode: mode, card: card, cue: cue)
  }

  /// 这些叶子里正在开新会话的：带着叶子或它的草稿（交出草稿时请求带的是草稿，送达后改记到叶子上）的开新会话请求还在路上，
  /// 或成功了、会话记录还没到（还没认领）。只认会被认领的那条（同 `claimLaunchedCards`）：它是带着这张卡的最近一次交给；
  /// 之后又交给了别处，或亲手绑定、解绑作废了它（`forgetLaunches`），就不算。
  public func launchingLeaves(_ leaves: [UUID]) throws -> Set<UUID> {
    guard !leaves.isEmpty else { return [] }
    return Set(try db.query(
      """
      WITH leaves(id) AS (SELECT value FROM json_each(?))
      SELECT CASE WHEN deliveryRequests.cardID IN leaves THEN deliveryRequests.cardID ELSE c.parentID END
      FROM deliveryRequests LEFT JOIN cards c ON c.id = deliveryRequests.cardID AND c.todoAt IS NULL
      WHERE (deliveryRequests.cardID IN leaves OR c.parentID IN leaves) AND deliveryRequests.mode = 'start'
        AND deliveryRequests.status IN ('pending', 'executing', 'succeeded') AND \(Self.launchUnclaimed)
        AND deliveryRequests.createdAt = (SELECT MAX(q.createdAt) FROM deliveryRequests q WHERE q.cardID = deliveryRequests.cardID)
      """, [Self.idList(leaves)]) { $0.uuid(0) })
  }

  /// 项目在哪台 Mac 上绑了文件夹：这台 Mac 绑了就是它，否则别的 Mac 里按名字排第一台；都没绑为 nil。
  private func launchHost(for project: UUID, preferring host: String?) throws -> String? {
    if let host, try directory(of: project) != nil { return host }
    let hosts = try db.query("SELECT hostID FROM directoryBindings WHERE projectID = ? ORDER BY hostName, hostID", [project]) { $0.text(0) }
    return host.flatMap { hosts.contains($0) ? $0 : nil } ?? hosts.first
  }

  /// 回答叶子的会话正在等的提问：选择框给选项原文或从 1 起的序号，确认框给是或否，输入框给文字。
  /// 带 `config` 时先请会话换上再答（同 `sayToLeaf`）；答案无效、没有提问时什么都不写。
  public func answerLeaf(_ leaf: UUID, _ value: String, config: PiConfig? = nil, host: String, cue: Bool = false) throws -> DeliveryRequest {
    let (card, session) = try requireSession(of: leaf)
    guard let question = session.state?.answerableQuestion, let promptID = question.promptID, let kind = question.kind.known else {
      throw CueStoreError.nothingToAnswer
    }
    let answer = try Self.answerValue(value.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, options: question.options)
    try requestConfig(config, of: card, in: session, host: host, cue: cue)
    return try requestAnswer(PiAnswer(promptID: promptID, value: answer), to: session.target, on: session.host(or: host), cue: cue)
  }

  private static func answerValue(_ value: String, kind: PiQuestionKind, options: [String]) throws -> PiAnswerValue {
    switch kind {
    case .text: return .text(value)
    case .select:
      if let hit = options.first(where: { $0 == value }) ?? options.first(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
        return .option(hit)
      }
      if let number = Int(value), options.indices.contains(number - 1) { return .option(options[number - 1]) }
      throw CueStoreError.invalidAnswer(options)
    case .confirm:
      switch value.lowercased() {
      case "yes", "y", "true", "是", "好", "确认", "ok": return .confirmed(true)
      case "no", "n", "false", "否", "不", "取消": return .confirmed(false)
      default: throw CueStoreError.invalidAnswer(["yes", "no"])
      }
    }
  }

  /// 停止叶子的会话正在跑的这一轮；此刻停不了（`PiSessionState.canStop`，与界面的停止按钮同一条）抛 `cannotStop`。
  public func stopLeaf(_ leaf: UUID, host: String, cue: Bool = false) throws -> DeliveryRequest {
    let (card, session) = try requireSession(of: leaf)
    guard session.state?.canStop == true else { throw CueStoreError.cannotStop(card.heading) }
    return try requestStop(of: session.target, on: session.host(or: host), cue: cue)
  }

  /// 完成一件事（连同它还没做完的步骤）并结束它交给的会话（写结束请求），返回结束请求。会话的去留只在这里定（界面点完成走
  /// `toggleDone`，你收下走 `answerCueMessage`，同一条路）：一个会话可以绑好几件事，它绑着的事（`tasks(boundTo:)`）都做完了才结束；
  /// 已结束的、结束不了的（`PiSessionState.canEnd`）、记录还没到的不动。结束请求写给会话所在的那台 Mac。`requireStepsDone` 为真时还有没完成的步骤就抛 `stepsRemaining`、
  /// 什么都不改（Cue 只收尾做完了的事；你点完成是连步骤一起完成）。
  /// `endsSessions` 为假时只完成、不结束会话（Cue 收尾一个步骤：会话留给下一步接着用，顶层任务完成时按上面的规则一起结束）。
  @discardableResult
  public func completeTask(
    _ task: UUID, requireStepsDone: Bool = false, endsSessions: Bool = true, cue: Bool = false
  ) throws -> [DeliveryRequest] {
    try write {
      if requireStepsDone { try checkStepsDone(task) }
      _ = try applyStatus(task, .done)
      return endsSessions ? try endFinishedSessions(of: task, cue: cue) : []
    }
  }

  /// 还有没完成的步骤就抛 `stepsRemaining`。
  private func checkStepsDone(_ task: UUID) throws {
    guard let link = try link(of: task), let card = try find(Card.self, task) else { throw CueStoreError.notFound }
    guard link.isTask else { throw CueStoreError.notATask }
    let remaining = try leaves(of: card).filter { $0.id != task && $0.completedAt == nil }.count
    guard remaining == 0 else { throw CueStoreError.stepsRemaining(remaining) }
  }

  /// Cue 收尾一件顶层任务：不直接完成，写一条"等你"请你收下（选项 `CueAcceptance.choices`、关联任务、正文是标题加证据要点）。
  /// 这件事已有没答的验收就不再写，返回那一条，`asked` 为假。步骤没做完抛 `stepsRemaining`。
  public func askToAccept(_ task: UUID, evidence: String) throws -> (message: CueMessage, asked: Bool) {
    try write {
      try checkStepsDone(task)
      guard let card = try find(Card.self, task) else { throw CueStoreError.notFound }
      let pending = try select(
        CueMessage.self, where: "author = 'cue' AND taskID = ? AND answeredAt IS NULL AND choices = ?",
        [task, JSONColumn.encode(CueAcceptance.choices)], orderBy: "createdAt, rowid")
      if let pending = pending.last { return (pending, false) }
      let now = Date.stamp
      let message = CueMessage(
        id: UUID(), author: .known(.cue), text: "「\(card.heading)」做好了，收下吗？\n\(evidence)", choices: CueAcceptance.choices, urgent: false,
        taskID: task, answer: nil, answeredAt: nil, deliveredAt: nil, createdAt: now, modifiedAt: now)
      try insert(message)
      return (message, true)
    }
  }

  /// 点任务的圆圈：待办与进行中都变完成（同 `completeTask`，连同结束做完了的会话），完成的回到待办。下一个状态按库里此刻的值决定，
  /// 读与改在一个事务里——界面手里的副本可能已过时，两次 `await` 之间也可能有同步来的改动插进来。返回新状态与结束请求。
  public func toggleDone(_ id: UUID) throws -> (status: TaskStatus, ended: [DeliveryRequest]) {
    try write {
      guard let card = try find(Card.self, id) else { throw CueStoreError.notFound }
      guard let current = card.status else { throw CueStoreError.notATask }
      let status = try applyStatus(id, current == .done ? .todo : .done)
      return (status, status == .done ? try endFinishedSessions(of: id, cue: false) : [])
    }
  }

  /// 刚完成的 `task`（与它的步骤）绑着的会话里，绑着的事都做完了、能结束的（`PiSessionState.canEnd`：终端里开的 Codex 会话这类
  /// 做不到的留着），请它所在的 Mac 结束。必须在写事务内调用。
  func endFinishedSessions(of task: UUID, cue: Bool) throws -> [DeliveryRequest] {
    let sessions = try db.query(
      "SELECT DISTINCT piSessionID FROM cards WHERE piSessionID IS NOT NULL AND id IN (\(Self.subtree(from: "SELECT ?")))", [task]
    ) { $0.text(0) }
    return try sessions.compactMap { sessionID in
      guard try tasks(boundTo: sessionID).allSatisfy({ $0.task.status == .done }),
        let state = try find(PiSessionState.self, PiSessionState.recordID(sessionID: sessionID)), state.canEnd
      else { return nil }
      return try requestControl(.end, of: SendTarget(kind: .piSession, name: state.title, ref: sessionID), on: state.hostID, cue: cue)
    }
  }

  /// 这件事由 Cue 跟进（`on`）还是你自己：给步骤也行，记在它的顶层任务上。返回顶层任务。
  @discardableResult
  public func setCueFollows(_ task: UUID, _ on: Bool) throws -> Card {
    try write {
      let top = try topTask(of: task)
      try db.run("UPDATE cards SET cueFollows = ?, modifiedAt = ? WHERE id = ? AND cueFollows != ?", [on, Date.stamp, top, on])
      return try find(Card.self, top)!
    }
  }

  /// 任务此刻在做的叶子：叶子就是它自己，有步骤的是第一个没完成的步骤（没有就第一个）。不是任务抛 `notATask`。
  public func workingLeaf(of task: UUID) throws -> Card {
    guard let link = try link(of: task) else { throw CueStoreError.notFound }
    guard link.isTask else { throw CueStoreError.notATask }
    guard let leaf = try find(Card.self, try promptHome(task)) else { throw CueStoreError.notFound }
    return leaf
  }

  /// 任务（或步骤）所在的顶层任务；不是任务抛 `notATask`。
  public func topTask(of task: UUID) throws -> UUID {
    guard let link = try link(of: task) else { throw CueStoreError.notFound }
    guard link.isTask else { throw CueStoreError.notATask }
    return try ancestors(of: task).last ?? task
  }

  private func requireLeaf(_ leaf: UUID) throws -> Card {
    guard let link = try link(of: leaf), let card = try find(Card.self, leaf) else { throw CueStoreError.notFound }
    guard link.isTask else { throw CueStoreError.notATask }
    guard try promptHome(leaf) == leaf else { throw CueStoreError.notALeaf }
    return card
  }

  /// 叶子与它的会话；没有会话抛 `noSession`（正在开会话抛 `launching`）。
  private func requireSession(of leaf: UUID) throws -> (card: Card, session: SessionTarget) {
    let card = try requireLeaf(leaf)
    guard card.piSessionID != nil else {
      throw try launchingLeaves([leaf]).isEmpty ? CueStoreError.noSession(card.heading) : CueStoreError.launching(card.heading)
    }
    return (card, try sessionTarget(of: card))
  }

  /// 发给叶子会话的目标与会话此刻的记录。
  private struct SessionTarget {
    var target: SendTarget
    var state: PiSessionState?

    /// 由哪台 Mac 执行：会话所在的那台；记录还没到时是发起的这台（`initiator`，手机为 nil）。
    func host(or initiator: String?) -> String? { state?.hostID ?? initiator }
    func host(or initiator: String) -> String { state?.hostID ?? initiator }
  }

  /// 叶子 `leaf`（绑着会话）的会话目标。
  private func sessionTarget(of leaf: Card) throws -> SessionTarget {
    let sessionID = leaf.piSessionID!
    let state = try find(PiSessionState.self, PiSessionState.recordID(sessionID: sessionID))
    return SessionTarget(target: SendTarget(kind: .piSession, name: state?.title ?? leaf.heading, ref: sessionID), state: state)
  }

  /// 这件事的叶子：有步骤的是各步骤（按顺序），没有步骤的是它自己。
  private func leaves(of task: Card) throws -> [Card] {
    let steps = try select(Card.self, where: "parentID = ? AND todoAt IS NOT NULL AND deletedAt IS NULL", [task.id], orderBy: "sortKey, id")
    return steps.isEmpty ? [task] : steps
  }

  // MARK: 看板与变化

  /// 所有项目（没进回收站的，顺序同 `projects()`）与有没有绑文件夹（本机或任何一台 Mac）：Cue 据此知道活能放进哪里、哪里开得了会话。
  public func cueProjects() throws -> [CueProject] {
    let bound = Set(try db.query("SELECT projectID FROM projectDirectories UNION SELECT projectID FROM directoryBindings") { $0.uuid(0) })
    return try projects().map { CueProject(id: $0.id, name: $0.name, hasFolder: bound.contains($0.id)) }
  }

  /// Cue 跟进的、没做完的顶层任务（没删除、没归档），按项目与手动顺序。
  public func cueBoard() throws -> [CueBoardItem] {
    try boardItems(try topTasks(followedOnly: true, where: Self.onBoard))
  }

  /// 所有没做完的顶层任务（不论谁在跟进；没删除、没归档），按项目顺序、未分类在最后，同项目按手动顺序：Cue 刚启用和巡视时看你手上有哪些事。
  public func openTopTasks() throws -> [CueBoardItem] {
    try boardItems(try topTasks(followedOnly: false, where: Self.onBoard))
  }

  private func boardItems(_ tasks: [Card]) throws -> [CueBoardItem] {
    guard !tasks.isEmpty else { return [] }
    let links = try CardLinks(db, around: tasks.map(\.id))
    let homes = try cards(Set(tasks.map { links.home(of: $0.id) }))
    let lastDone = try lastCompletedSteps(of: tasks.filter { task in homes[links.home(of: task.id)].map { $0.id != task.id && $0.completedAt != nil } ?? false })
    let leaves = homes.merging(lastDone.values.map { ($0.id, $0) }) { $1 }
    let sessions = try sessionStates(Array(leaves.values.compactMap(\.piSessionID)))
    let progress = try subtaskProgress(scope: "AND parentID IN (SELECT value FROM json_each(?))", [Self.idList(tasks.map(\.id))])
    let launching = try launchingLeaves(Array(leaves.keys))
    return tasks.map { task in
      let leaf = lastDone[task.id] ?? leaves[links.home(of: task.id)] ?? task
      let session = leaf.piSessionID.flatMap { sessions[$0] }
      return CueBoardItem(
        task: task, progress: progress[task.id], leaf: leaf, session: session, launching: launching.contains(leaf.id),
        since: session?.stateSince ?? leaf.startedAt ?? task.startedAt ?? task.todoAt ?? task.createdAt)
    }
  }

  /// 这些任务各自最后做完的那一步（同一时刻做完的取排在后面的），按任务 id。
  private func lastCompletedSteps(of tasks: [Card]) throws -> [UUID: Card] {
    guard !tasks.isEmpty else { return [:] }
    let steps = try select(
      Card.self, where: "parentID IN (SELECT value FROM json_each(?)) AND todoAt IS NOT NULL AND deletedAt IS NULL AND completedAt IS NOT NULL",
      [Self.idList(tasks.map(\.id))], orderBy: "completedAt, sortKey, id")
    return Dictionary(steps.compactMap { step in step.parentID.map { ($0, step) } }, uniquingKeysWith: { _, later in later })
  }

  /// 看板上的（跟进中的）：没做完、没归档。
  private static let onBoard = "t.completedAt IS NULL AND t.archivedAt IS NULL"

  /// `since` 之后 Cue 跟进的事里的变化，从早到晚：会话歇下、等回答、出错（按会话进入这个状态的时刻），叶子或任务完成，
  /// 你在会话的终端里亲自说了话，Cue 发起的请求没能执行（按本机得知结果的时刻）。`followed` 是上次醒来时看板上的任务 id：给了就和此刻的看板比，
  /// 多出来的是交给了 Cue（`joined`），少了的是不再跟进（`left`，完成了的只报 `done`）；nil 不比（如管理器刚启动）。
  public func cueChanges(since: Date, followed: Set<UUID>? = nil) throws -> [CueChange] {
    let tasks = try topTasks(followedOnly: true, where: "(t.completedAt IS NULL OR t.completedAt > ?)", [since])
    var changes: [CueChange] = []
    if let followed { changes += try membershipChanges(from: followed, since: since, reported: Set(tasks.map(\.id))) }
    if !tasks.isEmpty {
      let leaves = try tasks.flatMap { task in try leaves(of: task).map { (task: task, leaf: $0) } }
      let sessions = try sessionStates(leaves.compactMap(\.leaf.piSessionID))
      for task in tasks where task.completedAt.map({ $0 > since }) ?? false {
        changes.append(CueChange(kind: .done, taskID: task.id, task: task, at: task.completedAt!, recap: try latestRecap(of: task.id)))
      }
      for (task, leaf) in leaves {
        if leaf.id != task.id, let done = leaf.completedAt, done > since {
          changes.append(CueChange(kind: .done, taskID: task.id, task: task, leaf: leaf, at: done, recap: leaf.piSessionID.flatMap { sessions[$0] }?.recap))
        }
        guard let session = leaf.piSessionID.flatMap({ sessions[$0] }), session.stateSince > since else { continue }
        let (kind, detail): (CueChange.Kind?, String?) =
          switch session.state.known {
          case .settled: (.settled, nil)
          case .waitingForUser: (.waitingForUser, session.question?.text ?? session.detail)
          case .error: (.failed, session.detail)
          default: (nil, nil)
          }
        if let kind { changes.append(CueChange(kind: kind, taskID: task.id, task: task, leaf: leaf, at: session.stateSince, detail: detail, recap: session.recap)) }
      }
      // 一个会话可以绑好几件事：你在里面说的话算在它绑着的每件跟进的事上（同一件事的几个叶子共用它时只报一次）
      let bySession = Dictionary(grouping: leaves.filter { $0.leaf.piSessionID != nil }, by: { $0.leaf.piSessionID! })
        .mapValues { pairs in pairs.filter { pair in pairs.first { $0.task.id == pair.task.id }!.leaf.id == pair.leaf.id } }
      let typed = try select(
        PiChatMessage.self,
        where: "sessionID IN (SELECT value FROM json_each(?)) AND role = '\(PiChatRole.user.rawValue)' AND deliveryID IS NULL AND at > ?",
        [JSONColumn.encode(Array(bySession.keys)), since], orderBy: "at, seq")
      for message in typed {
        for pair in bySession[message.sessionID] ?? [] {
          changes.append(CueChange(
            kind: .youSpoke, taskID: pair.task.id, task: pair.task, leaf: pair.leaf, at: message.at, detail: CueFormat.plainText(message.text),
            recap: sessions[message.sessionID]?.recap))
        }
      }
      // 请求带着卡（叶子或它的草稿）就算在那个叶子上，否则算在会话绑着的叶子上
      let failed = try select(
        DeliveryRequest.self, where: "origin = '\(DeliveryOrigin.cue.rawValue)' AND status = 'failed' AND \(Self.resultKnownAt) > ?", [since],
        orderBy: "createdAt, rowid")
      for request in failed {
        let card = try request.cardID.flatMap { try find(Card.self, $0) }
        let pairs = card.map { card in leaves.filter { $0.leaf.id == card.id || $0.leaf.id == card.parentID } }
          ?? request.target.ref.flatMap { bySession[$0] } ?? []
        let at = request.resultReceivedAt ?? request.completedAt ?? request.createdAt
        let detail = "\(Self.action(request.mode))：\(request.failure ?? "")"
        for pair in pairs {
          changes.append(CueChange(
            kind: .failed, taskID: pair.task.id, task: pair.task, leaf: pair.leaf, at: at, detail: detail,
            recap: pair.leaf.piSessionID.flatMap { sessions[$0] }?.recap))
        }
      }
    }
    return changes.sorted { $0.at < $1.at }
  }

  /// 本机得知请求结果的时刻：发起的这台收到结果时记的（本机时钟），本机执行的是完成时刻。
  private static let resultKnownAt = "COALESCE(resultReceivedAt, completedAt)"

  /// 请求的动作在变化里的说法。
  private static func action(_ mode: Open<DeliveryMode>) -> String {
    switch mode.known {
    case .start: "开工"
    case .send, .steer, .followUp: "说话"
    case .answer: "作答"
    case .stop: "停下"
    case .end: "结束"
    default: mode.rawValue
    }
  }

  /// Cue 发起的请求最近一次失败的时刻（本机得知结果的时刻）：管理器订阅它，请求一失败就对账、醒来。
  public func lastCueRequestFailure() throws -> Date? {
    try db.first(
      "SELECT MAX(\(Self.resultKnownAt)) FROM deliveryRequests WHERE origin = '\(DeliveryOrigin.cue.rawValue)' AND status = 'failed'"
    ) { $0.dateOrNil(0) } ?? nil
  }

  /// 任务（自己或它的步骤）的会话里最近有动静的那个的摘要；没有会话为 nil。
  private func latestRecap(of task: UUID) throws -> PiRecap? {
    try select(
      PiSessionState.self,
      where: "sessionID IN (SELECT piSessionID FROM cards WHERE (id = ?1 OR parentID = ?1) AND todoAt IS NOT NULL AND piSessionID IS NOT NULL)",
      [task], orderBy: "stateSince DESC, id", limit: 1
    ).first?.recap
  }

  /// 跟进集合的差异：此刻看板上有、`followed` 里没有的是 `joined`；反过来的是 `left`，带上原因（永久删除的也报，只有 id）。
  /// 完成了的报 `done`（`reported` 里的已经报过，不重复）。
  private func membershipChanges(from followed: Set<UUID>, since: Date, reported: Set<UUID>) throws -> [CueChange] {
    let current = try topTasks(followedOnly: true, where: Self.onBoard)
    var changes = current.filter { !followed.contains($0.id) }.map { CueChange(kind: .joined, taskID: $0.id, task: $0, at: $0.modifiedAt) }
    let gone = followed.subtracting(current.map(\.id))
    let trashedProjects = Set(try select(Project.self, where: "deletedAt IS NOT NULL").map(\.id))
    let remaining = try cards(gone)
    for id in gone where remaining[id] == nil {
      changes.append(CueChange(kind: .left, taskID: id, task: nil, at: Date.stamp, detail: "删了"))
    }
    for card in remaining.values {
      if let done = card.completedAt {
        if !reported.contains(card.id), done > since { changes.append(CueChange(kind: .done, taskID: card.id, task: card, at: done, recap: try latestRecap(of: card.id))) }
        continue
      }
      let reason =
        if card.deletedAt != nil || card.projectID.map(trashedProjects.contains) == true { "删了" }
        else if card.archivedAt != nil { "归档了" }
        else if card.todoAt == nil { "改回了灵感" }
        else if card.parentID != nil { "挂到了别的任务下" }
        else { "你接手了" }
      changes.append(CueChange(kind: .left, taskID: card.id, task: card, at: card.modifiedAt, detail: reason))
    }
    return changes
  }

  /// 一件事的细节；给步骤也行，按它的顶层任务给。`rounds` 是每个叶子带几轮最近的问答。
  public func cueTaskDetail(_ task: UUID, rounds: Int = 3) throws -> CueTaskDetail {
    let top = try topTask(of: task)
    guard let card = try find(Card.self, top) else { throw CueStoreError.notFound }
    let leaves = try leaves(of: card)
    let sessions = try sessionStates(leaves.compactMap(\.piSessionID))
    let details = try leaves.map { leaf in
      let sessionID = leaf.piSessionID
      let recent = try sessionID.map {
        try select(
          PiChatMessage.self, where: "sessionID = ? AND role IN ('\(PiChatRole.user.rawValue)', '\(PiChatRole.pi.rawValue)')", [$0],
          orderBy: "seq DESC, id DESC", limit: rounds * 2
        ).reversed()
      } ?? []
      return CueLeafDetail(
        leaf: leaf, draft: try draft(of: leaf.id),
        session: sessionID.flatMap { sessions[$0] }, recent: Array(recent), previews: try sessionID.map(previews(of:)) ?? [])
    }
    return CueTaskDetail(task: card, progress: try subtaskProgress(of: top)[top], leaves: details)
  }

  /// 叶子的草稿（提示词）；没有为 nil。
  public func draft(of leaf: UUID) throws -> Card? {
    try Self.draft(of: leaf, in: db).flatMap { try find(Card.self, $0) }
  }

  /// 一批任务各自的预览（任务自己与它的步骤的会话发到手机上的，从早到晚）：一次查完，界面不必逐件取细节。没有预览的不在结果里。
  public func previews(ofTasks tasks: [UUID]) throws -> [UUID: [PiPreview]] {
    guard !tasks.isEmpty else { return [:] }
    let rows = try db.query(
      """
      WITH tasks(id) AS (SELECT value FROM json_each(?))
      SELECT \(PiPreview.columns.map { "p.\($0)" }.joined(separator: ", ")), CASE WHEN c.id IN tasks THEN c.id ELSE c.parentID END
      FROM previews p JOIN cards c ON c.piSessionID = p.sessionID
      WHERE c.todoAt IS NOT NULL AND c.deletedAt IS NULL AND (c.id IN tasks OR c.parentID IN tasks)
      ORDER BY p.createdAt, p.id
      """, [Self.idList(tasks)]
    ) { (task: $0.uuid(Int32(PiPreview.columns.count)), preview: PiPreview(row: $0)) }
    return Dictionary(grouping: rows, by: \.task).mapValues { $0.map(\.preview) }
  }

  /// 由 Cue 跟进的会话（Pi 的会话 id）：会话绑着的叶子所在的顶层任务 `cueFollows` 为真。界面与通知规则都读它。
  public func cueFollowedSessions() throws -> Set<String> {
    Set(try db.query("SELECT DISTINCT s.piSessionID FROM cards s WHERE s.piSessionID IS NOT NULL AND \(Self.followedByCue("s.piSessionID"))") { $0.text(0) })
  }

  /// 会话 `session`（SQL 表达式）绑着的叶子所在的顶层任务的 id：会话 → 叶子 → 顶层任务（任务最多两级，叶子没有上级就是它自己）。
  /// "这个会话由 Cue 跟进"与"你接手"只认这一段。
  static func topTasks(ofSession session: String) -> String {
    """
    SELECT CASE WHEN l.parentID IS NULL THEN l.id ELSE l.parentID END FROM cards l
    WHERE l.piSessionID = \(session) AND l.todoAt IS NOT NULL AND l.deletedAt IS NULL
    """
  }

  /// 会话 `session`（SQL 表达式）由 Cue 跟进。
  static func followedByCue(_ session: String) -> String {
    "EXISTS (SELECT 1 FROM cards t WHERE t.cueFollows = 1 AND t.parentID IS NULL AND t.deletedAt IS NULL AND t.id IN (\(topTasks(ofSession: session))))"
  }

  private func topTasks(followedOnly: Bool, where condition: String, _ arguments: [any SQLBindable] = []) throws -> [Card] {
    try db.query(
      """
      SELECT \(Card.columns.map { "t.\($0)" }.joined(separator: ", ")) FROM cards t LEFT JOIN projects p ON p.id = t.projectID
      WHERE \(followedOnly ? "t.cueFollows = 1 AND" : "") t.parentID IS NULL AND t.todoAt IS NOT NULL AND t.deletedAt IS NULL AND (p.id IS NULL OR p.deletedAt IS NULL)
        AND \(condition)
      ORDER BY t.projectID IS NULL, \(Self.projectOrder("p")), t.sortKey, t.id
      """, arguments
    ) { Card(row: $0) }
  }

  private func cards(_ ids: Set<UUID>) throws -> [UUID: Card] {
    Dictionary(
      uniqueKeysWithValues: try select(Card.self, where: "id IN (SELECT value FROM json_each(?))", [Self.idList(ids)]).map { ($0.id, $0) })
  }

  private func sessionStates(_ sessionIDs: [String]) throws -> [String: PiSessionState] {
    guard !sessionIDs.isEmpty else { return [:] }
    return Dictionary(
      try select(PiSessionState.self, where: "sessionID IN (SELECT value FROM json_each(?))", [JSONColumn.encode(sessionIDs)]).map { ($0.sessionID, $0) },
      uniquingKeysWith: { first, _ in first })
  }
}
