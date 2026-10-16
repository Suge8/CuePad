import CueText
import Foundation

// 任务交给会话、跟进与看板：界面与 Cue（经 MCP）共用这一份规则。`cue` 为真的写入标明来自 Cue（`DeliveryOrigin`）。

/// 任务交到哪（`CueStore.handOffPlan`）：界面（Mac 的"开始"、手机发给 Agent 的默认目标）与 Cue 的 `startLeaf` 共用这一份规则。
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
  /// 要开新会话（不是接着用已有的）：开工的第一句据此带不带顶层任务作背景（`CueStore.opening`）。
  public var opensSession: Bool { if case .session = destination { false } else { true } }
  /// 从这件事开的会话叫什么（`CueStore.sessionName(forCard:)`，`requestLaunch` 起名用的同一条规则）：叶子的标题；没有标题为 nil。
  public var name: String?
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

/// 看板（`CueStore.cueBoard`）：没做完的事，加上不归没做完的事的活会话。在做的（`isActive`）归值班的 Cue 管，其余是你手上的清单。
public struct CueBoard: Equatable, Sendable {
  public var tasks: [CueBoardItem]
  /// 不归没做完的事的活会话（`CueStore.isLoose`：他直接开的、终端里的，和只有已完成的事绑着的），最近有动静的在前。
  public var sessions: [PiSessionState]
  /// 在做的事：有在做的任务，或有不归没做完的事的活会话。
  public var isActive: Bool { !sessions.isEmpty || tasks.contains(where: \.isActive) }
}

/// 看板上的一件事：一个没做完的顶层任务。在做的（`isActive`）归值班的 Cue 管，其余是你手上的清单。
public struct CueBoardItem: Identifiable, Equatable, Sendable {
  public var task: Card
  /// 步骤完成了几个；没有步骤为 nil。
  public var progress: TaskProgress?
  /// 在做的叶子，至少一个（按步骤顺序）：没做完、开着会话（会话没结束，或做到一半被打断）、正在开会话或话正送进会话的每一个——
  /// 并行做的几步都在。一个都没有时是此刻该做的那一个：没有步骤是任务自己，否则第一个没完成的步骤；
  /// 步骤都做完了是最后做完的那一步（近况取它的会话，不落回第一步）。
  public var leaves: [CueBoardLeaf]
  public var id: UUID { task.id }
  public var isActive: Bool { leaves.contains(where: \.isActive) }
}

/// 看板上一件事里在做的一个叶子。
public struct CueBoardLeaf: Equatable, Sendable {
  public var leaf: Card
  /// 叶子的会话记录；还没开会话（或记录还没到）为 nil。
  public var session: PiSessionState?
  /// 正在为叶子开新会话（请求还没执行完，或开好了还没认领到）。
  public var launching: Bool
  /// 叶子还没绑会话、它的话正送进上一步的会话（`CueStore.sendingLeaves`；送到时绑上）。
  public var sending: Bool
  /// 停在当前状态的起点：会话进入当前状态的时刻，没有会话时是开始做或设为任务的时刻。
  public var since: Date

  /// 在做：会话没结束，或正在开会话、话正送进会话。
  public var isActive: Bool { launching || sending || session.map { $0.state != .known(.ended) } ?? false }
}

/// 某时刻之后，有会话的事或不归没做完的事的会话里的一处变化。
public struct CueChange: Equatable, Sendable {
  public enum Kind: String, Sendable, CaseIterable {
    /// 会话停下：这一轮做完歇下，或做到一半被打断（`interrupted`，会话状态是 `PiWorkState.interrupted`）
    case settled
    /// 会话在等回答
    case waitingForUser
    /// 会话出错，或 Cue 发起的请求（开工、停下、结束、换模型）没能执行（`detail` 是"动作：Mac 报的原因"；你发起的失败界面上看得见，不报）
    case failed
    /// Cue 说的话（说话、作答，`DeliveryMode.toSession`）没送到，而它还不知道：工具等结果超时、收到报告的那一轮半路断了都算；
    /// 记下已知道的（`CueStore.markCueTold`）不再报（`detail` 是 Mac 报的原因）。会话那边在等它接着说，所以与等回答一样立即叫醒它
    case undelivered
    /// 叶子或任务完成
    case done
  }

  public var kind: Kind
  /// 顶层任务；不归没做完的事的会话的变化为 nil。
  public var task: Card?
  /// 变化所在的叶子；任务本身的变化为 nil。
  public var leaf: Card?
  /// 变化所在的会话；任务完成这类不在会话上的变化为 nil。
  public var session: PiSessionState?
  /// 这一轮是他直接在会话里说的（`CueStore.turnOpener`，由事实推出，不另存）：Cue 说的、扩展投进来的机器消息开的都不算。
  public var byUser: Bool
  /// 事件发生的时刻（给 Cue 看）；分新旧看 `seq`
  public var at: Date
  /// 本机收到它的写入序号（`CueStore.lastWrite`）：越大越晚写进库
  public var seq: Int
  /// 提问、错误、哪个请求为什么没成。
  public var detail: String?
  /// 会话记录里已有的摘要：叶子的会话的；任务本身的变化取它最近有动静的那个会话的。
  public var recap: PiRecap?
  /// 停下是因为做到一半被打断（`PiWorkState.interrupted`），不是做完了。
  public var interrupted: Bool

  init(
    kind: Kind, task: Card?, leaf: Card? = nil, session: PiSessionState? = nil, byUser: Bool = false, at: Date, seq: Int,
    detail: String? = nil, recap: PiRecap? = nil, interrupted: Bool = false
  ) {
    self.kind = kind
    self.session = session
    self.byUser = byUser
    self.seq = seq
    self.interrupted = interrupted
    self.task = task
    self.leaf = leaf
    self.at = at
    self.detail = detail
    self.recap = recap
  }
}

/// Cue 的变化从哪算起（本机写入序号，`CueStore.lastWrite`）：会话的动静从 `sessions` 之后，任务完成从 `tasks` 之后。
/// 一轮做完时，会话的动静从醒来时读到的序号算起（这一轮里写进来的下次还在），完成从这一轮结束时算起（这一轮里多是 Cue 自己做完的）。
public struct CueMarks: Codable, Equatable, Sendable {
  public var sessions: Int
  public var tasks: Int

  public init(sessions: Int, tasks: Int) {
    self.sessions = sessions
    self.tasks = tasks
  }

  public init(_ both: Int) { self.init(sessions: both, tasks: both) }
}

/// 一件事的细节（Cue 的 peek）：叶子与各自的会话。
public struct CueTaskDetail: Equatable, Sendable {
  public var task: Card
  public var progress: TaskProgress?
  public var leaves: [CueLeafDetail]
}

public struct CueLeafDetail: Equatable, Sendable {
  public var leaf: Card
  /// 叶子的会话；还没开会话（或记录还没到）为 nil。
  public var session: CueSessionDetail?
  /// 还没绑会话、话正送进上一步的会话（同 `CueBoardItem.sending`）。
  public var sending: Bool
}

/// 一个会话的细节（Cue 的 peek）：记录、最近几轮问答与预览。
public struct CueSessionDetail: Equatable, Sendable {
  public var session: PiSessionState
  /// 最近几轮问答（会话里用户一方说的与 Agent 的回答），从早到晚。
  public var recent: [PiChatMessage]
  /// `recent` 里 Cue 说的那几条的请求 id（`cueSentDeliveries`，与会话页同一条规则，见 `PiChatMessage.saidByCue`）。
  public var cueSent: Set<UUID>
  public var previews: [PiPreview]
}

extension PiChatMessage {
  /// 用户一方的这句是 Cue 发进会话的（`cueSent` 是 `CueStore.cueSentDeliveries` 认出的请求 id）；其余都是用户说的——
  /// 在终端里打的与在 CuePad 里发的一样。会话页的气泡与 Cue 的 peek 都只认它。
  public func saidByCue(_ cueSent: Set<UUID>) -> Bool { role == .known(.user) && deliveryID.map(cueSent.contains) == true }
}

extension Card {
  /// 标题（`CueSummary` 的规则，唯一一处）：Cue 的工具、信封与界面都用它。空白的卡是空串（App 的 `title` 另给占位说法）。
  public var heading: String { CueSummary(body).title }

  /// 任务正文里标题下面的话（`CueLines.split`）：开工时连同标题一起发出。没有为 nil；写它只换这部分，标题那一行不动。
  public var rest: String? {
    get { CueLines.split(body).rest }
    set { body = CueLines.joined(title: CueLines.split(body).title, rest: newValue) }
  }
}

extension UUID {
  /// 给 Cue 与人看的短 id：小写的前 8 位（Cue 的工具接受至少 4 位的前缀）。
  public var shortID: String { String(uuidString.lowercased().prefix(8)) }
}

extension PiSessionState {
  /// 给 Cue 看的会话短 id：会话 id 的前 8 位（Cue 的工具接受至少 4 位的前缀）。
  public var shortID: String { String(sessionID.prefix(8)) }
}

extension CueStore {
  // MARK: 交给会话

  /// 任务交到哪：给任务，按它干活的叶子（`homeLeaf`）定。界面的"开始"、手机的发给 Agent 与 Cue 的开工都按它：
  /// 1. 叶子绑着会话，就交给那个会话；
  /// 2. 没绑，而同一件事的别的步骤绑着会话（`continuableSession`），就接着用它（上下文不丢；话送到时叶子绑上它；已结束的执行时先恢复）；
  /// 3. 否则在项目绑定的文件夹开一个以叶子标题命名的新会话（这台 Mac 绑了就在这台，否则别的 Mac 里按名字排第一台）。
  /// `fresh` 跳过 1、2，总是开新会话（界面"绑定会话"里的"开新会话"、Cue 开工带 fresh）；`agent` 给了就只接着用这一家的会话。
  /// `host` 是发起的这台 Mac，手机为 nil。不是任务抛 `notATask`。
  public func handOffPlan(_ task: UUID, host: String?, fresh: Bool = false, agent: AgentKind? = nil) throws -> HandOffPlan {
    let leaf = try workingLeaf(of: task)
    return HandOffPlan(
      leaf: leaf.id, destination: try destination(of: leaf, host: host, fresh: fresh, agent: agent), name: try sessionName(forCard: leaf.id))
  }

  private func destination(of leaf: Card, host: String?, fresh: Bool, agent: AgentKind?) throws -> HandOffPlan.Destination {
    if !fresh, let sessionID = leaf.piSessionID {
      let session = try sessionTarget(sessionID, name: leaf.heading)
      return .session(id: sessionID, title: session.target.name, host: session.host(or: host))
    }
    if !fresh, let session = try continuableSession(for: leaf.id, agent: agent) {
      return .session(id: session.sessionID, title: session.title, host: session.hostID)
    }
    guard let project = leaf.projectID else { return .unfiled }
    guard let launchHost = try launchHost(for: project, preferring: host) else {
      return .noFolder(project: project, projectName: try find(Project.self, project)?.name ?? "")
    }
    return .launch(project: project, host: launchHost)
  }

  /// 开工：把叶子（没有步骤的任务）的正文（标题连同下面的话）作为第一句交到 `handOffPlan` 定下的地方（界面的"开始"与 Cue 的 start
  /// 同一条规则，含接着用上一步的会话与 `fresh`）：接着用上一步的会话时等它做完再说，开新会话时它是第一句。正文发出后留在任务上。
  /// 接着用上一步的会话时，话送到才绑上（同开新会话"开成了才绑"），送到前算发送中（`sendingLeaves`）。
  /// 叶子已绑着会话（不带 `fresh`）抛 `alreadyStarted`：话在会话里说；正在开会话抛 `launching`，话还在送抛 `sending`，开不了会话抛 `noFolder`。
  /// `agent` 缺省是 Pi，给了就只接着用这一家的会话；`agent`、`model` 与 `thinking` 只用于开新会话。
  public func startLeaf(
    _ leaf: UUID, agent: AgentKind? = nil, fresh: Bool = false, model: PiModelKey? = nil, thinking: PiThinkingLevel? = nil,
    host: String, cue: Bool = false
  ) throws -> DeliveryRequest {
    let plan = try handOffPlan(leaf, host: host, fresh: fresh, agent: agent)
    let card = try requireLeaf(plan.leaf)
    if !fresh, card.piSessionID != nil { throw CueStoreError.alreadyStarted(card.heading) }
    let content = try opening(of: plan.leaf, plan.opensSession)
    switch plan.destination {
    case .session(let sessionID, _, _):
      if try !sendingLeaves([plan.leaf]).isEmpty { throw CueStoreError.sending(card.heading) }
      return try write { try say(content, to: try sessionTarget(sessionID, name: card.heading), mode: .followUp, card: card.id, host: host, cue: cue) }
    case .launch(let project, let host):
      guard try launchingLeaves([plan.leaf]).isEmpty else { throw CueStoreError.launching(card.heading) }
      let launch = PiLaunch(
        project: project, prompt: content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : content, token: UUID().uuidString,
        agent: agent ?? .pi, model: model, thinking: thinking)
      return try requestLaunch(launch, title: plan.name ?? "", on: host, card: card.id, cue: cue)
    case .noFolder(_, let projectName): throw CueStoreError.noFolder(projectName)
    case .unfiled: throw CueStoreError.noFolder("")
    }
  }

  /// 开工的第一句（界面的"开始"与 Cue 的 start 都按它）：开新会话的步骤先带上顶层任务的标题与正文作背景，空一行接这一步的；
  /// 接着用已有会话的只发这一步的（上下文已在会话里）。变量已填。
  public func opening(of leaf: UUID, _ newSession: Bool) throws -> String {
    guard let card = try find(Card.self, leaf) else { throw CueStoreError.notFound }
    var parts = [card]
    if newSession, let top = try find(Card.self, try topTask(of: leaf)), top.id != leaf { parts.insert(top, at: 0) }
    return parts
      .map { CueFormat.readable(CueVariables.fill($0.body, values: $0.variableValues)) }
      .joined(separator: "\n\n")
  }

  /// 同一件事别的步骤绑着、没在被请求结束的会话里最近有动静的那个（`agent` 给了就只要这一家的）：下一步接着用它，上下文不丢。
  /// 已结束的也算：执行的 Mac 连上目标会话时先恢复它（`MacExecutor`）。
  private func continuableSession(for leaf: UUID, agent: AgentKind?) throws -> PiSessionState? {
    let top = try topTask(of: leaf)
    guard top != leaf, let task = try find(Card.self, top) else { return nil }
    let ending = Set(try db.query(
      "SELECT targetRef FROM deliveryRequests WHERE mode = '\(DeliveryMode.end.rawValue)' AND status IN ('pending', 'executing') AND targetRef IS NOT NULL"
    ) { $0.text(0) })
    let sessions = try sessionStates(try leaves(of: task).compactMap(\.piSessionID))
    return sessions.values
      .filter { session in !ending.contains(session.sessionID) && agent.map { session.agent == .known($0) } != false }
      .max { $0.stateSince < $1.stateSince }
  }

  /// 对会话说一句（界面的回复框与 Cue 的 say 共用这一条）：
  /// 1. 会话在等 CuePad 能代答的提问（`PiSessionState.answerableQuestion`）时，这句就是答案（`answerValue`）；答不上抛 `invalidAnswer`，什么都不写。
  /// 2. 否则按 `mode` 发出：`send` 直接发送、`followUp` 等它做完再说、`steer` 马上说（规则见 `say`）。
  /// 带 `config`（模型、思考强度）时先请会话换上（与界面换模型同一种请求），两条按先后执行；换不了模型抛 `cannotChangeModel`，什么都不写。
  /// 会话已结束也照说：执行它的 Mac 先恢复它。说话不改任务的状态：已完成的事收到话仍是完成。`card` 是这句带着的卡，
  /// `name` 是会话记录还没到时对它的称呼，`host` 是记录还没到时由哪台 Mac 执行。
  public func speak(
    _ content: String, to sessionID: String, name: String = "", mode: DeliveryMode = .send, card: UUID? = nil, config: PiConfig? = nil,
    host: String, cue: Bool = false
  ) throws -> DeliveryRequest {
    try write {
      let session = try sessionTarget(sessionID, name: name)
      var answer: PiAnswer?
      if let question = session.state?.answerableQuestion, let promptID = question.promptID, let kind = question.kind.known {
        let value = CueFormat.plainText(content).trimmingCharacters(in: .whitespacesAndNewlines)
        answer = PiAnswer(promptID: promptID, value: try Self.answerValue(value, kind: kind, options: question.options, allowsOther: question.allowsOther))
      }
      try requestConfig(config, in: session, host: host, cue: cue)
      if let answer {
        return try insertDelivery(answer.stored, to: session.target, on: session.host(or: host), mode: .answer, card: card, cue: cue)
      }
      return try say(content, to: session, mode: mode, card: card, host: host, cue: cue)
    }
  }

  /// 叶子绑着的会话；没有抛 `noSession`（正在开会话抛 `launching`，话正送进上一步的会话抛 `sending`）。
  public func leafSession(_ leaf: UUID) throws -> String {
    let card = try requireLeaf(leaf)
    guard let sessionID = card.piSessionID else {
      if try !launchingLeaves([leaf]).isEmpty { throw CueStoreError.launching(card.heading) }
      if try !sendingLeaves([leaf]).isEmpty { throw CueStoreError.sending(card.heading) }
      throw CueStoreError.noSession(card.heading)
    }
    return sessionID
  }

  /// 说话之前先请会话换上 `config`；换不了模型（`AgentCapabilities.model`，记录没到也算不知道、不换）抛 `cannotChangeModel`。
  /// 必须在写事务内、写别的之前调用：抛错时什么都没写。
  private func requestConfig(_ config: PiConfig?, in session: SessionTarget, host: String, cue: Bool) throws {
    guard let config else { return }
    guard session.state?.capabilities.contains(.model) == true else { throw CueStoreError.cannotChangeModel(session.target.name) }
    _ = try insertDelivery(config.stored, to: session.target, on: session.host(or: host), mode: .config, cue: cue)
  }

  /// 交给会话一句话：方式只按意图与这家做得到的写（`AgentCapabilities.steer`），会话忙不忙由 Mac 执行时定——
  /// `steer` 马上说（会话歇着时就是直接说；做不到马上说的写等它做完再说），`followUp` 等它做完再说（歇着时也是直接说），`send` 直接发送。
  /// Cue 说的话在用户发起的那一轮里（`inUserTurn`）不插嘴，一律等这一轮做完再说。
  /// 收不了图片的只发文字（`AgentCapabilities.images`）。必须在写事务内调用。
  private func say(
    _ content: String, to session: SessionTarget, mode: DeliveryMode, card: UUID?, host: String, cue: Bool
  ) throws -> DeliveryRequest {
    // 记录还没到时 Cue 不知道做不做得到马上说，按做不到写；界面只在做得到时给出马上说，照你选的写
    let canSteer = session.state.map { $0.capabilities.contains(.steer) } ?? !cue
    let mode = try mode == .steer && !(canSteer && !(cue && inUserTurn(session.target.ref))) ? .followUp : mode
    let content = session.state?.capabilities.contains(.images) == false ? CueFormat.withoutImages(content) : content
    return try insertDelivery(content, to: session.target, on: session.host(or: host), mode: mode, card: card, cue: cue)
  }

  /// 会话正在跑的这一轮是他发起的（`turnOpener`）。
  private func inUserTurn(_ sessionID: String?) throws -> Bool {
    guard let sessionID, try sessionState(sessionID)?.state.known?.isTurnRunning == true else { return false }
    return try turnOpener(sessionID) == .user
  }

  /// 会话最近（或正在跑）的这一轮是谁开的，唯一的一处（"他说的"标记与他那一轮里 Cue 不插嘴都只认它）：
  /// 取会话里最近一条你一方或机器的消息——机器消息（扩展投进来的，如 FireCode 交回结果）既不算他的也不算 Cue 的；
  /// 你一方的按来源分（`PiChatMessage.saidByCue`）。会话里还没有这两种消息为 nil。
  private func turnOpener(_ sessionID: String) throws -> TurnOpener? {
    guard let last = try select(
      PiChatMessage.self, where: "sessionID = ? AND role IN ('\(PiChatRole.user.rawValue)', '\(PiChatRole.machine.rawValue)')", [sessionID],
      orderBy: "seq DESC, id DESC", limit: 1
    ).first else { return nil }
    guard last.role == .known(.user) else { return .machine }
    return last.saidByCue(try cueSentDeliveries(among: [last.deliveryID].compactMap(\.self))) ? .cue : .user
  }

  private enum TurnOpener { case user, cue, machine }

  /// 这些叶子里正在开新会话的：带着叶子的开新会话请求还在路上，或成功了、会话记录还没到（还没认领）。
  /// 只认会被认领的那条（同 `claimLaunchedCards`）：它是带着这张卡的最近一次交给；之后又交给了别处，或亲手绑定、解绑作废了它（`forgetLaunches`），就不算。
  public func launchingLeaves(_ leaves: [UUID]) throws -> Set<UUID> {
    guard !leaves.isEmpty else { return [] }
    return Set(try db.query(
      """
      SELECT cardID FROM deliveryRequests
      WHERE cardID IN (SELECT value FROM json_each(?)) AND mode = 'start' AND status IN ('pending', 'executing', 'succeeded')
        AND \(Self.launchUnclaimed)
        AND createdAt = (SELECT MAX(q.createdAt) FROM deliveryRequests q WHERE q.cardID = deliveryRequests.cardID)
      """, [Self.idList(leaves)]) { $0.uuid(0) })
  }

  /// 这些叶子里话正在送进会话的：带着叶子、发给会话的话（送达时叶子绑上那个会话）还没有结果。
  /// 接着用上一步的会话时，开工到话送到之间就是这样：还没绑上，看板与 peek 写"发送中"。
  public func sendingLeaves(_ leaves: [UUID]) throws -> Set<UUID> {
    guard !leaves.isEmpty else { return [] }
    let modes = [DeliveryMode.send, .steer, .followUp].map { "'\($0.rawValue)'" }.joined(separator: ", ")
    return Set(try db.query(
      """
      SELECT cardID FROM deliveryRequests
      WHERE cardID IN (SELECT value FROM json_each(?)) AND mode IN (\(modes)) AND status IN ('pending', 'executing')
      """, [Self.idList(leaves)]) { $0.uuid(0) })
  }

  /// 项目在哪台 Mac 上绑了文件夹：这台 Mac 绑了就是它，否则别的 Mac 里按名字排第一台；都没绑为 nil。
  private func launchHost(for project: UUID, preferring host: String?) throws -> String? {
    if let host, try directory(of: project) != nil { return host }
    let hosts = try db.query("SELECT hostID FROM directoryBindings WHERE projectID = ? ORDER BY hostName, hostID", [project]) { $0.text(0) }
    return host.flatMap { hosts.contains($0) ? $0 : nil } ?? hosts.first
  }

  /// 一句话作为提问的答案：选择题给选项原文或从 1 起的序号，收自己写的回答的（`PiQuestion.allowsOther`）其余文字照写；
  /// 确认题给是或否；文字题照写。答不上抛 `invalidAnswer`。
  private static func answerValue(_ value: String, kind: PiQuestionKind, options: [String], allowsOther: Bool) throws -> PiAnswerValue {
    switch kind {
    case .text: return .text(value)
    case .select:
      if let hit = options.first(where: { $0 == value }) ?? options.first(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
        return .option(hit)
      }
      if let number = Int(value), options.indices.contains(number - 1) { return .option(options[number - 1]) }
      if allowsOther, !value.isEmpty { return .text(value) }
      throw CueStoreError.invalidAnswer(options)
    case .confirm:
      switch value.lowercased() {
      case "yes", "y", "true", "是", "好", "确认", "ok": return .confirmed(true)
      case "no", "n", "false", "否", "不", "取消": return .confirmed(false)
      default: throw CueStoreError.invalidAnswer(["是", "否"])
      }
    }
  }

  /// 停止会话正在跑的这一轮；此刻停不了（`PiSessionState.canStop`，与界面的停止按钮同一条）抛 `cannotStop`。
  public func stopSession(_ sessionID: String, host: String, cue: Bool = false) throws -> DeliveryRequest {
    let session = try sessionTarget(sessionID, name: "")
    guard session.state?.canStop == true else { throw CueStoreError.cannotStop(session.target.name) }
    return try requestStop(of: session.target, on: session.host(or: host), cue: cue)
  }

  /// Cue 做完一件事：算不算做完由 Cue 按证据自己定，不请你确认。还有没完成的步骤抛 `stepsRemaining`、什么都不改；否则完成它，
  /// 结束没人再用的会话（`endUnusedSessions`，同你点圆圈 `toggleDone`，请求算 Cue 发起的）。顶层任务同时写一条给你的结果
  /// （`CueReport.text`：标题加证据要点，关联任务）：做完告诉你；你不认可就把它改回没做完，或直接告诉 Cue。
  /// 证据的条数与长短由调用方（Cue 的工具）把关。返回这条结果（步骤为 nil）与结束请求。
  @discardableResult
  public func finishTask(_ task: UUID, evidence: [String]) throws -> (report: CueMessage?, ended: [DeliveryRequest]) {
    try write {
      try checkStepsDone(task)
      guard let card = try find(Card.self, task) else { throw CueStoreError.notFound }
      _ = try applyStatus(task, .done)
      let ended = try endUnusedSessions(of: task, cue: true)
      guard card.parentID == nil else { return (nil, ended) }
      return (try insertCueMessage(.cue, text: CueReport.text(task: card.heading, evidence: evidence), task: task), ended)
    }
  }

  /// 还有没完成的步骤就抛 `stepsRemaining`。
  private func checkStepsDone(_ task: UUID) throws {
    guard let link = try link(of: task), let card = try find(Card.self, task) else { throw CueStoreError.notFound }
    guard link.isTask else { throw CueStoreError.notATask }
    let remaining = try leaves(of: card).filter { $0.id != task && $0.completedAt == nil }.count
    guard remaining == 0 else { throw CueStoreError.stepsRemaining(remaining) }
  }

  /// 点任务的圆圈：待办与进行中都变完成（连同结束做完了的会话，同 `finishTask`），完成的不再算做完（`reopen`）。下一个状态按库里此刻的值决定，
  /// 读与改在一个事务里——界面手里的副本可能已过时，两次 `await` 之间也可能有同步来的改动插进来。返回新状态与结束请求。
  public func toggleDone(_ id: UUID) throws -> (status: TaskStatus, ended: [DeliveryRequest]) {
    try write {
      guard let card = try find(Card.self, id) else { throw CueStoreError.notFound }
      guard let current = card.status else { throw CueStoreError.notATask }
      guard current != .done else {
        try reopen([id])
        return (try find(Card.self, id)?.status ?? .todo, [])
      }
      return (try applyStatus(id, .done), try endUnusedSessions(of: id, cue: false))
    }
  }

  /// Cue 的 edit reopen：把已完成的事改回没做完（`reopen`，同点掉圆圈）；没完成的什么都不改。
  public func reopenTask(_ id: UUID) throws {
    try write { try reopen([id]) }
  }

  /// 不再算做完，只在这里写：点掉圆圈（`toggleDone`）、Cue 的 edit reopen（`reopenTask`）、给已完成的事加步骤（`createTask(_:under:)`）、
  /// 把完成的改成别的状态（`applyStatus`）。`tasks` 连同各自已完成的上级清掉完成时间：开始过的回到进行中，没开始过的回到待办；
  /// 在归档里的，整件连同下级取回。说话不经这里：任务的状态只由明确的动作改。必须在写事务内调用。
  func reopen(_ tasks: [UUID]) throws {
    let chains = try tasks.map { [$0] + (try ancestors(of: $0)) }
    let done = try select(
      Card.self, where: "id IN (SELECT value FROM json_each(?)) AND todoAt IS NOT NULL AND completedAt IS NOT NULL",
      [Self.idList(chains.flatMap { $0 })])
    guard !done.isEmpty else { return }
    let reopened = Set(done.map(\.id))
    try db.run(
      "UPDATE cards SET completedAt = NULL, modifiedAt = ? WHERE id IN (SELECT value FROM json_each(?))", [Date.stamp, Self.idList(reopened)])
    try setArchived(chains.filter { !reopened.isDisjoint(with: $0) }.map { $0.last! }, at: nil)
  }

  /// 会话的去留只在这里定。一件事里的叶子做完了（你点圆圈 `toggleDone`、Cue 做完 `finishTask`），或叶子换去别的会话的那一刻
  /// （开工、交话时开新会话或交给别的会话都经 `insertDelivery`，你绑定经 `bindSession`），对这件事里绑着的会话各看一遍，没人再用就请它所在的 Mac 结束：
  /// 1. 有没做完、也没在开新会话的叶子绑着它（别的事的叶子也算），或有话正送进去（接着用它时话送到才绑上），留着；
  /// 2. 这件事的下一步（排在最前的没做完的步骤）还没开工、也没在往别处交，照交给的规则（`handOffPlan`）默认接着用它，留着；
  /// 3. 其余结束：没有下一步了、下一步换了别的会话、整件事完成。做不到的（`PiSessionState.canEnd`：终端里开的 Codex 会话这类）留着；
  ///    已结束的、记录还没到的不动。
  /// `task` 是这件事里的任意一个任务。返回结束请求。必须在写事务内调用。
  @discardableResult
  func endUnusedSessions(of task: UUID, cue: Bool) throws -> [DeliveryRequest] {
    guard let top = try find(Card.self, try topTask(of: task)) else { return [] }
    let sessions = try db.query(
      "SELECT DISTINCT piSessionID FROM cards WHERE piSessionID IS NOT NULL AND id IN (\(Self.subtree(from: "SELECT ?")))", [top.id]
    ) { $0.text(0) }
    guard !sessions.isEmpty else { return [] }
    let open = try leaves(of: top).filter { $0.completedAt == nil }
    let launching = try launchingLeaves(open.map(\.id))
    var used = Set(open.filter { !launching.contains($0.id) }.compactMap(\.piSessionID))
    if let next = open.first, next.id != top.id, next.piSessionID == nil, !launching.contains(next.id), try sendingLeaves([next.id]).isEmpty,
      let continued = try continuableSession(for: next.id, agent: nil)
    {
      used.insert(continued.sessionID)
    }
    return try sessions.compactMap { sessionID in
      guard !used.contains(sessionID), try db.first(Self.usedElsewhere, [sessionID, top.id], { _ in true }) == nil,
        let state = try find(PiSessionState.self, PiSessionState.recordID(sessionID: sessionID)), state.canEnd
      else { return nil }
      return try requestControl(.end, of: SendTarget(kind: .piSession, name: state.title, ref: sessionID), on: state.hostID, cue: cue)
    }
  }

  /// 会话（?1）在这件事（以 ?2 为根）之外还有用：别的事没做完的叶子绑着它，或有话正送进去。
  private static let usedElsewhere = """
    SELECT 1 WHERE EXISTS (
        SELECT 1 FROM cards WHERE piSessionID = ?1 AND todoAt IS NOT NULL AND completedAt IS NULL AND deletedAt IS NULL AND archivedAt IS NULL
          AND id NOT IN (\(subtree(from: "SELECT ?2"))))
      OR EXISTS (
        SELECT 1 FROM deliveryRequests WHERE targetRef = ?1 AND mode IN (\(toSessionModes)) AND status IN ('pending', 'executing'))
    """

  /// 任务此刻在做的叶子：叶子就是它自己，有步骤的是第一个没完成的步骤（没有就第一个）。不是任务抛 `notATask`。
  public func workingLeaf(of task: UUID) throws -> Card {
    guard let link = try link(of: task) else { throw CueStoreError.notFound }
    guard link.isTask else { throw CueStoreError.notATask }
    guard let leaf = try find(Card.self, try homeLeaf(task)) else { throw CueStoreError.notFound }
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
    guard try homeLeaf(leaf) == leaf else { throw CueStoreError.notALeaf }
    return card
  }

  /// 发给叶子会话的目标与会话此刻的记录。
  private struct SessionTarget {
    var target: SendTarget
    var state: PiSessionState?

    /// 由哪台 Mac 执行：会话所在的那台；记录还没到时是发起的这台（`initiator`，手机为 nil）。
    func host(or initiator: String?) -> String? { state?.hostID ?? initiator }
    func host(or initiator: String) -> String { state?.hostID ?? initiator }
  }

  /// 发给会话 `sessionID` 的目标；会话记录还没到时以 `name` 称呼它。
  private func sessionTarget(_ sessionID: String, name: String) throws -> SessionTarget {
    let state = try find(PiSessionState.self, PiSessionState.recordID(sessionID: sessionID))
    return SessionTarget(target: SendTarget(kind: .piSession, name: state?.title ?? name, ref: sessionID), state: state)
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

  /// 看板：所有没做完的顶层任务（没删除、没归档），按项目顺序、未分类在最后，同项目按手动顺序；加上不归没做完的事的活会话（`isLoose`）。
  /// 在做的（`CueBoard.isActive`）是值班的 Cue 管的，其余是你手上的清单（Cue 巡视时看）。信封、变化与 peek 都按它。
  public func cueBoard() throws -> CueBoard {
    CueBoard(
      tasks: try boardItems(try topTasks(where: Self.onBoard)),
      sessions: try select(PiSessionState.self, where: Self.isLoose("piSessionStates"), orderBy: "stateSince DESC, id"))
  }

  /// 最近完成、绑过会话的 `limit` 件顶层任务（没删除，归档了的也算），最近完成的在前，各带它（自己或步骤）的会话里最近有动静的那个此刻的样子：
  /// Cue 据此找能接着用的旧会话（不带参数的 peek 末尾列出）。会话记录还没到的不列。
  public func cueRecentlyDone(limit: Int) throws -> [(task: Card, session: PiSessionState)] {
    try topTasks(where: "t.completedAt IS NOT NULL AND \(Self.hasSession)", orderBy: "t.completedAt DESC, t.id", limit: limit)
      .compactMap { task in try latestSession(of: task.id).map { (task, $0) } }
  }

  /// 表 `alias`（会话记录）里不归没做完的事的活会话：没结束，没有没做完的任务绑着它，
  /// 也不是哪个没做完的任务以前用过的（`Card.formerSessionIDs`）。只有已完成的事绑着的算在内：它还活着，Cue 管它。
  /// 回收站与归档里的任务不算。
  static func isLoose(_ alias: String) -> String {
    let open = "c.deletedAt IS NULL AND c.completedAt IS NULL AND c.archivedAt IS NULL"
    return """
      \(alias).state <> '\(PiWorkState.ended.rawValue)'
        AND NOT EXISTS (
          SELECT 1 FROM cards c WHERE c.piSessionID = \(alias).sessionID AND \(open) AND c.todoAt IS NOT NULL)
        AND NOT EXISTS (
          SELECT 1 FROM cards c, json_each(c.formerSessionIDs) f
          WHERE c.formerSessionIDs IS NOT NULL AND c.todoAt IS NOT NULL AND \(open) AND f.value = \(alias).sessionID)
      """
  }

  private func boardItems(_ tasks: [Card]) throws -> [CueBoardItem] {
    guard !tasks.isEmpty else { return [] }
    let links = try CardLinks(db, around: tasks.map(\.id))
    let homes = try cards(Set(tasks.map { links.home(of: $0.id) }))
    let lastDone = try lastCompletedSteps(of: tasks.filter { task in homes[links.home(of: task.id)].map { $0.id != task.id && $0.completedAt != nil } ?? false })
    // 每件事的候选：没做完的叶子（并行做的几步都在），加上没有在做的步骤时落回的那一个
    let steps = Dictionary(grouping: try select(
      Card.self, where: "parentID IN (SELECT value FROM json_each(?)) AND todoAt IS NOT NULL AND deletedAt IS NULL AND completedAt IS NULL",
      [Self.idList(tasks.map(\.id))], orderBy: "sortKey, id"
    ), by: { $0.parentID! })
    let fallback = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, lastDone[$0.id] ?? homes[links.home(of: $0.id)] ?? $0) })
    let candidates = tasks.map { task in (steps[task.id] ?? []) + [fallback[task.id]!] }
    let all = candidates.flatMap { $0 }
    let sessions = try sessionStates(all.compactMap(\.piSessionID))
    let progress = try subtaskProgress(scope: "AND parentID IN (SELECT value FROM json_each(?))", [Self.idList(tasks.map(\.id))])
    let launching = try launchingLeaves(all.map(\.id))
    let sending = try sendingLeaves(all.filter { $0.piSessionID == nil }.map(\.id))
    return zip(tasks, candidates).map { task, candidates in
      let leaves = candidates.map { leaf in
        let session = leaf.piSessionID.flatMap { sessions[$0] }
        return CueBoardLeaf(
          leaf: leaf, session: session, launching: launching.contains(leaf.id), sending: sending.contains(leaf.id),
          since: session?.stateSince ?? leaf.startedAt ?? task.startedAt ?? task.todoAt ?? task.createdAt)
      }
      let open = leaves.dropLast().filter(\.isActive)
      return CueBoardItem(task: task, progress: progress[task.id], leaves: open.isEmpty ? [leaves.last!] : Array(open))
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

  /// 看板上的：没做完、没归档。
  private static let onBoard = "t.completedAt IS NULL AND t.archivedAt IS NULL"

  /// 顶层任务 `t` 自己或它的步骤绑着会话。
  private static let hasSession = """
    EXISTS (SELECT 1 FROM cards l WHERE (l.id = t.id OR l.parentID = t.id) AND l.todoAt IS NOT NULL AND l.deletedAt IS NULL AND l.piSessionID IS NOT NULL)
    """

  /// 本机最近一次写入的序号：构成 Cue 的变化的那几列被写时（本机写入与同步落库一样），那一行盖上新序号（见 `Schema` 38）。
  /// Cue 按它分新旧，不按事件时刻：事件可能晚到（机器忙、从别的设备同步来），时刻早于上次醒来。
  public func lastWrite() throws -> Int { try db.first("SELECT seq FROM writeCounter") { Int($0.int(0)) } ?? 0 }

  /// 写入序号 `marks` 之后有会话的事与不归没做完的事的活会话（`isLoose`）里的变化，按事件时刻从早到晚：会话歇下（这一轮的回复读到之后，见 `sessionChange`）、等回答、出错，Cue 发起的请求没能执行
  /// （这些从 `marks.sessions` 之后算；还没开成会话的事也报），叶子或任务完成（从 `marks.tasks` 之后算）。
  /// 会话里用户说的话不另报：他那一轮歇下时 Cue 照常醒来，变化标着这一轮是他说的（`CueChange.byUser`）。
  public func cueChanges(after marks: CueMarks) throws -> [CueChange] {
    let tasks = try topTasks(where: "(t.completedAt IS NULL OR t.writeSeq > ?) AND \(Self.hasSession)", [marks.tasks])
    var changes: [CueChange] = []
    let leaves = try tasks.flatMap { task in try leaves(of: task).map { (task: task, leaf: $0) } }
    let sessions = try sessionStates(leaves.compactMap(\.leaf.piSessionID))
    let cardSeqs = try writeSeqs(of: .cards, "id", (leaves.map(\.leaf.id) + tasks.map(\.id)).map { $0.uuidString.lowercased() })
    let sessionSeqs = try writeSeqs(of: .piSessionStates, "sessionID", Array(sessions.keys))
    func seq(_ card: Card) -> Int { cardSeqs[card.id.uuidString.lowercased()] ?? 0 }
    for task in tasks where task.completedAt != nil && seq(task) > marks.tasks {
      changes.append(CueChange(kind: .done, task: task, at: task.completedAt!, seq: seq(task), recap: try latestRecap(of: task.id)))
    }
    for (task, leaf) in leaves {
      if leaf.id != task.id, let done = leaf.completedAt, seq(leaf) > marks.tasks {
        changes.append(CueChange(kind: .done, task: task, leaf: leaf, at: done, seq: seq(leaf), recap: leaf.piSessionID.flatMap { sessions[$0] }?.recap))
      }
      guard let session = leaf.piSessionID.flatMap({ sessions[$0] }), let written = sessionSeqs[session.sessionID], written > marks.sessions else { continue }
      if let change = try sessionChange(session, seq: written, task: task, leaf: leaf) { changes.append(change) }
    }
    let loose = try selectWritten(PiSessionState.self, where: "\(Self.isLoose("piSessionStates"))", [], orderBy: "writeSeq")
    // 刚完成的事的会话两边都有：算在那件事上，不报第二遍
    for (session, written) in loose where written > marks.sessions && sessions[session.sessionID] == nil {
      if let change = try sessionChange(session, seq: written, task: nil, leaf: nil) { changes.append(change) }
    }
    // 一个会话可以绑好几件事：没带卡的失败算在它绑着的每件事上（同一件事的几个叶子共用它时只报一次）；不归没做完的事的会话算在它自己上
    let bySession = Dictionary(grouping: leaves.filter { $0.leaf.piSessionID != nil }, by: { $0.leaf.piSessionID! })
      .mapValues { pairs in pairs.filter { pair in pairs.first { $0.task.id == pair.task.id }!.leaf.id == pair.leaf.id } }
      .mapValues { $0.map { (task: Optional($0.task), leaf: Optional($0.leaf)) } }
    let looseByID = Dictionary(loose.map { ($0.0.sessionID, [(task: Card?.none, leaf: Card?.none)]) }, uniquingKeysWith: { first, _ in first })
    let failed = try selectWritten(
      DeliveryRequest.self, where: "origin = '\(DeliveryOrigin.cue.rawValue)' AND status = 'failed' AND cueToldAt IS NULL AND writeSeq > ?",
      [marks.sessions], orderBy: "writeSeq")
    for (request, written) in failed {
      let pairs = try request.cardID.map(failedLeaf) ?? request.target.ref.flatMap { bySession[$0] ?? looseByID[$0] } ?? []
      let at = request.resultReceivedAt ?? request.completedAt ?? request.createdAt
      let spoken = request.mode.known.map(DeliveryMode.toSession.contains) == true
      let reason = request.failure ?? DeliveryRequest.unexplainedFailure
      let session = try request.target.ref.flatMap(sessionState)
      for pair in pairs {
        changes.append(CueChange(
          kind: spoken ? .undelivered : .failed, task: pair.task, leaf: pair.leaf, session: session, at: at, seq: written,
          detail: spoken ? reason : "\(Self.action(request.mode))：\(reason)", recap: session?.recap))
      }
    }
    return changes.sorted { $0.at < $1.at }
  }

  /// 会话停在的状态是一处变化时（歇下、被打断、等回答、出错）的那条变化；在跑、已结束为 nil。
  /// 歇下要等这一轮的回复读到才算：状态由桥报，问答由 Mac 读会话文件写，两路先后不定（Claude Code 的轮末标记写在报歇下的钩子之后）。
  /// 提问还在处理中（`pendingPrompt`）就是回复还没读到；一轮都没做过（刚开出来就歇着）没有动静。读到时问答一变，这一行盖上新序号，变化随之出现。
  private func sessionChange(_ session: PiSessionState, seq: Int, task: Card?, leaf: Card?) throws -> CueChange? {
    let (kind, detail): (CueChange.Kind?, String?) =
      switch session.state.known {
      case .settled where session.pendingPrompt != nil || (session.lastPrompt == nil && session.lastReply == nil): (nil, nil)
      case .settled, .interrupted: (.settled, nil)
      case .waitingForUser: (.waitingForUser, session.question?.text ?? session.detail)
      case .error: (.failed, session.detail)
      default: (nil, nil)
      }
    guard let kind else { return nil }
    return CueChange(
      kind: kind, task: task, leaf: leaf, session: session, byUser: try turnOpener(session.sessionID) == .user, at: session.stateSince, seq: seq,
      detail: detail, recap: session.recap, interrupted: session.state == .known(.interrupted))
  }

  /// 请求带着的叶子与它的顶层任务；卡不在了、不是任务（已删、改回灵感）为空。
  private func failedLeaf(_ card: UUID) throws -> [(task: Card?, leaf: Card?)] {
    guard let leaf = try find(Card.self, card), leaf.deletedAt == nil, leaf.isTask,
      let task = try find(Card.self, try topTask(of: leaf.id)), task.deletedAt == nil
    else { return [] }
    return [(task, leaf)]
  }

  private func sessionState(_ sessionID: String) throws -> PiSessionState? {
    try find(PiSessionState.self, PiSessionState.recordID(sessionID: sessionID))
  }

  /// 请求的动作在变化里的说法（说的话没送到另报 `undelivered`，不经这里）。
  private static func action(_ mode: Open<DeliveryMode>) -> String {
    switch mode.known {
    case .start: "开工"
    case .config: "换模型"
    case .stop: "停下"
    case .end: "结束"
    default: mode.rawValue
    }
  }

  /// Cue 已经知道这些请求没送到：说话工具当场报给了它，且收到报告的那一轮好好做完了（值班的管理器记下，`CueKeeper`）。
  /// 之后不再作为变化报给它（`CueChange.Kind.undelivered`）。本机列：管理器与它的工具在同一台 Mac 上。
  public func markCueTold(_ requests: [UUID]) throws {
    guard !requests.isEmpty else { return }
    try write {
      try db.run(
        "UPDATE deliveryRequests SET cueToldAt = ? WHERE id IN (SELECT value FROM json_each(?)) AND status = 'failed'",
        [Date.stamp, Self.idList(requests)])
    }
  }

  /// 任务（自己或它的步骤）的会话里最近有动静的那个的摘要；没有会话为 nil。
  private func latestRecap(of task: UUID) throws -> PiRecap? { try latestSession(of: task)?.recap }

  /// 任务（自己或它的步骤）绑着的会话里最近有动静的那个；没有为 nil。
  private func latestSession(of task: UUID) throws -> PiSessionState? {
    try select(
      PiSessionState.self,
      where: "sessionID IN (SELECT piSessionID FROM cards WHERE (id = ?1 OR parentID = ?1) AND todoAt IS NOT NULL AND piSessionID IS NOT NULL)",
      [task], orderBy: "stateSince DESC, id", limit: 1
    ).first
  }

  /// 一件事的细节；给步骤也行，按它的顶层任务给。`rounds` 是每个叶子带几轮最近的问答。
  public func cueTaskDetail(_ task: UUID, rounds: Int = 3) throws -> CueTaskDetail {
    let top = try topTask(of: task)
    guard let card = try find(Card.self, top) else { throw CueStoreError.notFound }
    let leaves = try leaves(of: card)
    let sessions = try sessionStates(leaves.compactMap(\.piSessionID))
    let sending = try sendingLeaves(leaves.filter { $0.piSessionID == nil }.map(\.id))
    let details = try leaves.map { leaf in
      CueLeafDetail(
        leaf: leaf, session: try leaf.piSessionID.flatMap { sessions[$0] }.map { try sessionDetail($0, rounds: rounds) },
        sending: sending.contains(leaf.id))
    }
    return CueTaskDetail(task: card, progress: try subtaskProgress(of: top)[top], leaves: details)
  }

  /// 一个会话的细节（Cue 的 peek 给会话时）；没有记录为 nil。
  public func cueSessionDetail(_ sessionID: String, rounds: Int = 3) throws -> CueSessionDetail? {
    try sessionState(sessionID).map { try sessionDetail($0, rounds: rounds) }
  }

  private func sessionDetail(_ session: PiSessionState, rounds: Int) throws -> CueSessionDetail {
    let recent = try select(
      PiChatMessage.self, where: "sessionID = ? AND role IN ('\(PiChatRole.user.rawValue)', '\(PiChatRole.pi.rawValue)')", [session.sessionID],
      orderBy: "seq DESC, id DESC", limit: rounds * 2
    ).reversed()
    return CueSessionDetail(
      session: session, recent: Array(recent), cueSent: try cueSentDeliveries(among: recent.compactMap(\.deliveryID)),
      previews: try previews(of: session.sessionID))
  }

  /// Cue 说的会话：会话 id、至少 4 位的 id 前缀，或会话名（不分大小写）；id 对上的优先，都按最近有动静的在前。
  public func sessions(matching ref: String) throws -> [PiSessionState] {
    let key = ref.trimmingCharacters(in: .whitespaces)
    let byID = try select(
      PiSessionState.self, where: "sessionID = ?1 OR (length(?1) >= 4 AND sessionID >= ?1 AND sessionID < ?1 || '~')", [key],
      orderBy: "stateSince DESC, id")
    if !byID.isEmpty { return byID }
    return try select(PiSessionState.self, where: "title = ? COLLATE NOCASE", [key], orderBy: "stateSince DESC, id")
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

  private func topTasks(
    where condition: String, _ arguments: [any SQLBindable] = [], orderBy: String? = nil, limit: Int? = nil
  ) throws -> [Card] {
    try db.query(
      """
      SELECT \(Card.columns.map { "t.\($0)" }.joined(separator: ", ")) FROM cards t LEFT JOIN projects p ON p.id = t.projectID
      WHERE t.parentID IS NULL AND t.todoAt IS NOT NULL AND t.deletedAt IS NULL AND (p.id IS NULL OR p.deletedAt IS NULL)
        AND \(condition)
      ORDER BY \(orderBy ?? "\(Self.taskProjectOrder), t.sortKey, t.id")\(limit.map { " LIMIT \($0)" } ?? "")
      """, arguments
    ) { Card(row: $0) }
  }

  private func cards(_ ids: Set<UUID>) throws -> [UUID: Card] {
    Dictionary(
      uniqueKeysWithValues: try select(Card.self, where: "id IN (SELECT value FROM json_each(?))", [Self.idList(ids)]).map { ($0.id, $0) })
  }

  /// 这些行的写入序号，按 `key` 列（同一个键有几行取最新的）。
  private func writeSeqs(of table: Table, _ key: String, _ keys: [String]) throws -> [String: Int] {
    guard !keys.isEmpty else { return [:] }
    return Dictionary(
      try db.query(
        "SELECT \(key), MAX(writeSeq) FROM \(table.rawValue) WHERE \(key) IN (SELECT value FROM json_each(?)) GROUP BY \(key)", [JSONColumn.encode(keys)]
      ) { ($0.text(0), Int($0.int(1))) },
      uniquingKeysWith: { first, _ in first })
  }

  /// 满足条件的行，带上它的写入序号。
  private func selectWritten<R: Record>(
    _ type: R.Type, where condition: String, _ arguments: [any SQLBindable], orderBy: String
  ) throws -> [(R, Int)] {
    try db.query(
      "SELECT \(R.columns.joined(separator: ", ")), writeSeq FROM \(R.table.rawValue) WHERE \(condition) ORDER BY \(orderBy)", arguments
    ) { (R(row: $0), Int($0.int(Int32(R.columns.count)))) }
  }

  private func sessionStates(_ sessionIDs: [String]) throws -> [String: PiSessionState] {
    guard !sessionIDs.isEmpty else { return [:] }
    return Dictionary(
      try select(PiSessionState.self, where: "sessionID IN (SELECT value FROM json_each(?))", [JSONColumn.encode(sessionIDs)]).map { ($0.sessionID, $0) },
      uniquingKeysWith: { first, _ in first })
  }
}
