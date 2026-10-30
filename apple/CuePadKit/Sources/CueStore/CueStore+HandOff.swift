import CueText
import Foundation

// 任务交给会话、跟进与看板：界面与 Cue（经 MCP）共用这一份规则。`cue` 为真的写入标明来自 Cue（`DeliveryOrigin`）。

extension CueStore {
  /// 任务交到哪：给任务，按它干活的叶子（`homeLeaf`）定。界面的"开始"、手机的发给 Agent 与 Cue 的开工都按它：
  /// 1. 叶子绑着会话，就交给那个会话；
  /// 2. 没绑，而同一件事的别的子任务绑着会话（`continuableSession`），就接着用它（上下文不丢；话送到时叶子绑上它；已结束的执行时先恢复）；
  /// 3. 否则在项目的文件夹开一个以叶子标题命名的新会话，由哪台 Mac 开见 `launchHost`。
  /// `fresh` 跳过 1、2，总是开新会话（界面"绑定会话"里的"开新会话"、Cue 开工带 fresh）；`agent` 给了就只接着用这一家的会话。
  /// `host` 是发起的这台 Mac，手机为 nil。不是任务抛 `notATask`；要开新会话而一台 Mac 都没有（只会在手机上）抛 `noMac`。
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

  /// 开工：把叶子（没有子任务的任务）的正文（标题连同下面的话）作为第一句交到 `handOffPlan` 定下的地方（界面的"开始"与 Cue 的 start
  /// 同一条规则，含接着用上一步的会话与 `fresh`）：接着用上一步的会话时是它的下一句（规则同 `speak`），开新会话时它是第一句。正文发出后留在任务上。
  /// 接着用上一步的会话时，话送到才绑上（同开新会话"开成了才绑"），送到前算发送中（`sendingLeaves`）。
  /// 叶子已绑着会话（不带 `fresh`）抛 `alreadyStarted`：话在会话里说；正在开会话抛 `launching`，话还在送抛 `sending`。
  /// `agent` 给了就只接着用这一家的会话；`agent`、`model`（这家的写法，`AgentKind.modelKey`）与 `thinking` 只用于开新会话，
  /// 开哪家见 `launchAgent`。
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
      let key = try model.map(kind.requiredModelKey)
      let launch = PiLaunch(
        project: project, prompt: content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : content, token: UUID().uuidString,
        agent: kind, model: key, thinking: thinking)
      return try requestLaunch(launch, title: plan.name ?? "", on: host, card: card.id, cue: cue)
    }
  }

  /// 在 `host` 上开新会话用哪家：没指定是那台 Mac 的默认（`MacAgents.preferred`，同界面的新会话），一家都不能用抛 `noAgent`；
  /// 指定的那家那台 Mac 记着不能用（没装、没登录……）抛 `agentUnavailable` 带原因，不开出一个起不来的会话。
  private func launchAgent(_ agent: AgentKind?, on host: String) throws -> AgentKind {
    let agents = try macAgents(on: host)
    guard let agent else {
      guard let preferred = agents.preferred(nil) else { throw CueStoreError.noAgent(agents.whyNone) }
      return preferred
    }
    if let problem = agents.problems.first(where: { $0.kind == agent }) { throw CueStoreError.agentUnavailable("\(agent.name) \(problem.reason)") }
    return agent
  }

  /// 开工的第一句（界面的"开始"与 Cue 的 start 都按它）：开新会话的子任务先带上顶层任务的标题与正文作背景，空一行接这一步的；
  /// 接着用已有会话的只发这一步的（上下文已在会话里）。变量已填。
  public func opening(of leaf: UUID, _ newSession: Bool) throws -> String {
    guard let card = try find(Card.self, leaf) else { throw CueStoreError.notFound }
    var parts = [card]
    if newSession, let top = try find(Card.self, try topTask(of: leaf)), top.id != leaf { parts.insert(top, at: 0) }
    return parts
      .map { CueVariables.fill($0.body, values: $0.variableValues).trimmingCharacters(in: .whitespacesAndNewlines) }
      .joined(separator: "\n\n")
  }

  /// 同一件事别的子任务绑着、没在被请求结束的会话里最近有动静的那个（`agent` 给了就只要这一家的）：下一步接着用它，上下文不丢。
  /// 已结束的也算：执行的 Mac 连上目标会话时先恢复它（`MacExecutor`）。
  func continuableSession(for leaf: UUID, agent: AgentKind?) throws -> PiSessionState? {
    let top = try topTask(of: leaf)
    guard top != leaf, let task = try find(Card.self, top) else { return nil }
    let ending = Set(try db.query(
      "SELECT targetRef FROM deliveryRequests WHERE mode = '\(DeliveryMode.end.rawValue)' AND status IN (\(DeliveryStatus.openSQL)) AND targetRef IS NOT NULL"
    ) { $0.text(0) })
    let sessions = try sessionStates(try leaves(of: task).compactMap(\.piSessionID))
    return sessions.values
      .filter { session in !ending.contains(session.sessionID) && agent.map { session.agent == .known($0) } != false }
      .max { $0.stateSince < $1.stateSince }
  }

  /// 尚未收尾的交接请求，按叶子批量分组。占位与运行展示都读这些原记录；是否仍在路上只由 `Speech.trip` 判定。
  /// 未确认与不认识的结果仍占位；只有明确未交出才允许自动另开或再发。
  public func handoffRequests(for leaves: [UUID]) throws -> [UUID: [DeliveryRequest]] {
    guard !leaves.isEmpty else { return [:] }
    let requests = try select(
      DeliveryRequest.self,
      where: """
        cardID IN (SELECT value FROM json_each(?)) AND (
          (mode = '\(DeliveryMode.start.rawValue)' AND status != '\(DeliveryStatus.failed.rawValue)'
            AND \(Self.launchUnclaimed) AND \(Self.latestHandoff("deliveryRequests")))
          OR (mode = '\(DeliveryMode.send.rawValue)' AND status NOT IN ('\(DeliveryStatus.failed.rawValue)', '\(DeliveryStatus.succeeded.rawValue)')))
        """, [Self.idList(leaves)], orderBy: "createdAt, rowid")
    return Dictionary(grouping: requests, by: { $0.cardID! })
  }

  /// 尚未认领到会话的开会话意图，包括未知结果；它防重复，不代表此刻在跑。
  public func launchingLeaves(_ leaves: [UUID]) throws -> Set<UUID> {
    Set(try handoffRequests(for: leaves).compactMap { leaf, requests in
      requests.contains { $0.mode == .known(.start) } ? leaf : nil
    })
  }

  /// 尚未收尾的发话意图，包括未知结果；它防重复，不代表此刻在跑。
  func sendingLeaves(_ leaves: [UUID]) throws -> Set<UUID> {
    Set(try handoffRequests(for: leaves).compactMap { leaf, requests in
      requests.contains { $0.mode == .known(.send) } ? leaf : nil
    })
  }

  /// 项目在哪台 Mac 上绑了文件夹：这台 Mac 绑了就是它，否则别的 Mac 里按名字排第一台；都没绑为 nil。
  /// 在项目里开新会话由哪台 Mac 开（`host` 是发起的这台，手机为 nil）：项目绑着文件夹就在绑了的那台（发起的这台绑了就是它，
  /// 否则按 Mac 名排第一台）——那里是它真正的代码；哪台都没绑时是发起的这台，手机发起的是 `workMac`。那台 Mac 开工时建工作区并绑定
  /// （`MacExecutor`）。一台 Mac 都没有为 nil。
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
