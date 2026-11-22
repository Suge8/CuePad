import CueText
import Foundation


extension CueStore {
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

  public func startLeaf(
    _ leaf: UUID, agent: AgentKind? = nil, fresh: Bool = false, model: String? = nil, thinking: ThinkingLevel? = nil,
    host: String, cue: Bool = false, said: [String] = []
  ) throws -> DeliveryRequest {
    let plan = try handOffPlan(leaf, host: host, fresh: fresh, agent: agent)
    let card = try requireLeaf(plan.leaf)
    if !fresh, card.piSessionID != nil { throw CueStoreError.alreadyStarted(card.heading) }
    let content = (said + [try opening(of: plan.leaf, plan.opensSession)]).filter { !$0.isEmpty }.joined(separator: "\n\n")
    let handoffs = try handoffRequests(for: [plan.leaf])[plan.leaf] ?? []
    if handoffs.contains(where: { $0.mode == .known(.send) }) { throw CueStoreError.sending(card.heading) }
    if handoffs.contains(where: { $0.mode == .known(.start) }) { throw CueStoreError.launching(card.heading) }
    switch plan.destination {
    case .session(let sessionID, _, _):
      return try write { try say(content, to: try sessionTarget(sessionID, name: card.heading), card: card.id, host: host, cue: cue) }
    case .launch(let project, let host):
      let kind = try launchAgent(agent, on: host)
      let key = try model.map { try cueModelKey($0, of: kind, host: host) }
      let launch = LaunchRequest(
        project: project, prompt: content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : content, token: UUID().uuidString,
        agent: kind, model: key, thinking: thinking)
      return try requestLaunch(launch, title: plan.name ?? "", on: host, card: card.id, cue: cue)
    }
  }

  private func launchAgent(_ agent: AgentKind?, on host: String) throws -> AgentKind {
    let agents = try macAgents(on: host)
    guard let agent else {
      guard let preferred = agents.preferred(nil) else { throw CueStoreError.noAgent(agents.whyNone) }
      return preferred
    }
    if let problem = agents.problems.first(where: { $0.kind == agent }) { throw CueStoreError.agentUnavailable("\(agent.name) \(problem.reason)") }
    return agent
  }

  public func opening(of leaf: UUID, _ newSession: Bool) throws -> String {
    guard let card = try find(Card.self, leaf) else { throw CueStoreError.notFound }
    var parts = [card]
    if newSession, let top = try find(Card.self, try topTask(of: leaf)), top.id != leaf { parts.insert(top, at: 0) }
    return parts
      .map { CueVariables.fill($0.body, values: $0.variableValues).trimmingCharacters(in: .whitespacesAndNewlines) }
      .joined(separator: "\n\n")
  }

  func continuableSession(for leaf: UUID, agent: AgentKind?, ignoringEndOf: String? = nil) throws -> SessionState? {
    let top = try topTask(of: leaf)
    guard top != leaf, let task = try find(Card.self, top) else { return nil }
    let ending = Set(try db.query("SELECT targetRef FROM deliveryRequests AS r WHERE \(DeliveryRequest.endingSQL("r")) AND targetRef IS NOT NULL") { $0.text(0) })
    let sessions = try sessionStates(try leaves(of: task).compactMap(\.piSessionID))
    return sessions.values
      .filter { session in (session.sessionID == ignoringEndOf || !ending.contains(session.sessionID)) && agent.map { session.agent == .known($0) } != false }
      .max { $0.stateSince < $1.stateSince }
  }

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

  public func launchingLeaves(_ leaves: [UUID]) throws -> Set<UUID> {
    Set(try handoffRequests(for: leaves).compactMap { leaf, requests in
      requests.contains { $0.mode == .known(.start) } ? leaf : nil
    })
  }

  func sendingLeaves(_ leaves: [UUID]) throws -> Set<UUID> {
    Set(try handoffRequests(for: leaves).compactMap { leaf, requests in
      requests.contains { $0.mode == .known(.send) } ? leaf : nil
    })
  }

  func launchHost(for project: UUID, preferring host: String?) throws -> String? {
    if let host, try directory(of: project) != nil { return host }
    let hosts = try db.query(
      "SELECT hostID FROM directoryBindings WHERE projectID = ? ORDER BY \(DirectoryBinding.macNameSQL), hostID", [project]) { $0.text(0) }
    return try host.flatMap { hosts.contains($0) ? $0 : nil } ?? hosts.first ?? host ?? workMac()
  }

  public func workMac() throws -> String? {
    if let host = try cueProfile()?.activeHost { return host }
    return try allMacAgents().first?.hostID
  }
}
