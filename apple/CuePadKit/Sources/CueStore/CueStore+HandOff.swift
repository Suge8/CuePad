import CueText
import Foundation


extension CueStore {
  /// 界面的“开始”、手机的发给 Agent 与 Cue 的开工都按它。`fresh` 总是开新会话；`agent` 给了就只接着用这一家的会话。`host` 是发起的这台 Mac，手机为 nil。不是任务抛 `notATask`；要开新会话而一台 Mac 都没有（只会在手机上）抛 `noMac`。
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
    guard let launchHost = try launchHost(for: leaf.projectID, preferring: host) else { throw CueStoreError.noMac }
    return .launch(project: leaf.projectID, host: launchHost)
  }

  /// 正文发出后留在任务上。接着用上一步的会话时话送到才绑上（同开新会话“开成了才绑”），送到前算发送中（`sendingLeaves`）。叶子已绑着会话（不带 `fresh`）抛 `alreadyStarted`：话在会话里说；正在开会话抛 `launching`，话还在送抛 `sending`。`agent`、`model`、`thinking` 只用于开新会话，开哪家见 `launchAgent`。
  public func startLeaf(
    _ leaf: UUID, agent: AgentKind? = nil, fresh: Bool = false, model: String? = nil, thinking: PiThinkingLevel? = nil,
    host: String, cue: Bool = false
  ) throws -> DeliveryRequest {
    let plan = try handOffPlan(leaf, host: host, fresh: fresh, agent: agent)
    let card = try requireLeaf(plan.leaf)
    if !fresh, card.piSessionID != nil { throw CueStoreError.alreadyStarted(card.heading) }
    let content = try opening(of: plan.leaf, plan.opensSession)
    let handoffs = try handoffRequests(for: [plan.leaf])[plan.leaf] ?? []
    if handoffs.contains(where: { $0.mode == .known(.send) }) { throw CueStoreError.sending(card.heading) }
    if handoffs.contains(where: { $0.mode == .known(.start) }) { throw CueStoreError.launching(card.heading) }
    switch plan.destination {
    case .session(let sessionID, _, _):
      return try write { try say(content, to: try sessionTarget(sessionID, name: card.heading), card: card.id, host: host, cue: cue) }
    case .launch(let project, let host):
      let kind = try launchAgent(agent, on: host)
      let key = try model.map { try cueModelKey($0, of: kind, host: host) }
      let launch = PiLaunch(
        project: project, prompt: content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : content, token: UUID().uuidString,
        agent: kind, model: key, thinking: thinking)
      return try requestLaunch(launch, title: plan.name ?? "", on: host, card: card.id, cue: cue)
    }
  }

  /// 一家都不能用抛 `noAgent`；指定的那家那台 Mac 记着不能用抛 `agentUnavailable` 带原因，不开出一个起不来的会话。
  private func launchAgent(_ agent: AgentKind?, on host: String) throws -> AgentKind {
    let agents = try macAgents(on: host)
    guard let agent else {
      guard let preferred = agents.preferred(nil) else { throw CueStoreError.noAgent(agents.whyNone) }
      return preferred
    }
    if let problem = agents.problems.first(where: { $0.kind == agent }) { throw CueStoreError.agentUnavailable("\(agent.name) \(problem.reason)") }
    return agent
  }

  /// 开新会话的子任务先带上顶层任务的标题与正文作背景；接着用已有会话的只发这一步的（上下文已在会话里）。
  public func opening(of leaf: UUID, _ newSession: Bool) throws -> String {
    guard let card = try find(Card.self, leaf) else { throw CueStoreError.notFound }
    var parts = [card]
    if newSession, let top = try find(Card.self, try topTask(of: leaf)), top.id != leaf { parts.insert(top, at: 0) }
    return parts
      .map { CueVariables.fill($0.body, values: $0.variableValues).trimmingCharacters(in: .whitespacesAndNewlines) }
      .joined(separator: "\n\n")
  }

  /// 已结束的也算：执行的 Mac 连上目标会话时先恢复它（`MacExecutor`）。
  func continuableSession(for leaf: UUID, agent: AgentKind?, ignoringEndOf: String? = nil) throws -> PiSessionState? {
    let top = try topTask(of: leaf)
    guard top != leaf, let task = try find(Card.self, top) else { return nil }
    let ending = Set(try db.query(
      "SELECT targetRef FROM deliveryRequests WHERE mode = '\(DeliveryMode.end.rawValue)' AND status IN (\(DeliveryStatus.openSQL)) AND targetRef IS NOT NULL"
    ) { $0.text(0) })
    let sessions = try sessionStates(try leaves(of: task).compactMap(\.piSessionID))
    return sessions.values
      .filter { session in (session.sessionID == ignoringEndOf || !ending.contains(session.sessionID)) && agent.map { session.agent == .known($0) } != false }
      .max { $0.stateSince < $1.stateSince }
  }

  /// 未确认与不认识的结果仍占位；只有明确未交出才允许自动另开或再发。
  /// 未确认与不认识的结果仍占位；只有明确未交出才允许自动另开或再发。
  public func handoffRequests(for leaves: [UUID]) throws -> [UUID: [DeliveryRequest]] {
    guard !leaves.isEmpty else { return [:] }
    let requests = try select(
      DeliveryRequest.self,
      where: """
        cardID IN (SELECT value FROM json_each(?))
          AND sessionBindingRevision IS (SELECT sessionBindingRevision FROM cards WHERE id = deliveryRequests.cardID) AND (
          (mode = '\(DeliveryMode.start.rawValue)' AND status != '\(DeliveryStatus.failed.rawValue)'
            AND \(Self.launchUnclaimed) AND \(Self.latestHandoff("deliveryRequests")))
          OR (mode = '\(DeliveryMode.send.rawValue)' AND status NOT IN ('\(DeliveryStatus.failed.rawValue)', '\(DeliveryStatus.succeeded.rawValue)')))
        """, [Self.idList(leaves)], orderBy: "createdAt, rowid")
    return Dictionary(grouping: requests, by: { $0.cardID! })
  }

  /// 包括未知结果；它防重复，不代表此刻在跑。
  public func launchingLeaves(_ leaves: [UUID]) throws -> Set<UUID> {
    Set(try handoffRequests(for: leaves).compactMap { leaf, requests in
      requests.contains { $0.mode == .known(.start) } ? leaf : nil
    })
  }

  /// 包括未知结果；它防重复，不代表此刻在跑。
  func sendingLeaves(_ leaves: [UUID]) throws -> Set<UUID> {
    Set(try handoffRequests(for: leaves).compactMap { leaf, requests in
      requests.contains { $0.mode == .known(.send) } ? leaf : nil
    })
  }

  /// `host` 是发起的这台，手机为 nil。项目绑着文件夹就在绑了的那台（发起的这台绑了就是它，否则按 Mac 名排第一台）——那里是它真正的代码；哪台都没绑时是发起的这台，手机发起的是 `workMac`。那台 Mac 开工时建工作区并绑定（`MacExecutor`）。一台 Mac 都没有为 nil。
  func launchHost(for project: UUID, preferring host: String?) throws -> String? {
    if let host, try directory(of: project) != nil { return host }
    let hosts = try db.query(
      "SELECT hostID FROM directoryBindings WHERE projectID = ? ORDER BY \(DirectoryBinding.macNameSQL), hostID", [project]) { $0.text(0) }
    return try host.flatMap { hosts.contains($0) ? $0 : nil } ?? hosts.first ?? host ?? workMac()
  }

  /// 手机上没绑文件夹的项目交给哪台 Mac：Cue 运行的那台（活本来就在那里派），没启用 Cue 时按名字排第一台；一台 Mac 都没有为 nil。
  public func workMac() throws -> String? {
    if let host = try cueProfile()?.activeHost { return host }
    return try allMacAgents().first?.hostID
  }
}
