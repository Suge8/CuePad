import Foundation

public struct MacAgents: Equatable, Sendable {
  public var hostID: String
  public var name: String?
  public var agents: [MacAgent]
  public var problems: [MacAgentProblem]
  public var modifiedAt: Date

  public init(hostID: String, name: String? = nil, agents: [MacAgent], problems: [MacAgentProblem] = [], modifiedAt: Date) {
    self.hostID = hostID
    self.name = name
    self.agents = agents
    self.problems = problems
    self.modifiedAt = modifiedAt
  }

  public var shownName: String { Self.shownName(name) }
  public static let unnamed = String(localized: "未命名的 Mac")
  static func shownName(_ name: String?) -> String { name ?? unnamed }
  static func nameSQL(host column: String) -> String { "(SELECT name FROM macAgents WHERE macAgents.hostID = \(column))" }

  public func agent(_ kind: AgentKind) -> MacAgent? { agents.first { $0.kind == kind } }

  public func problem(_ kind: AgentKind) -> MacAgentProblem.Reason? { problems.first { $0.kind == kind }?.reason }

  public var kinds: [AgentKind] { agents.map(\.kind) }

  public func preferred(_ last: AgentKind?) -> AgentKind? {
    if let last, kinds.contains(last) { return last }
    return kinds.first
  }

  public var whyNone: String {
    problems.isEmpty ? String(localized: "还没查过有哪些 Agent 能用") : problems.map { "\($0.kind.name) \($0.reason)" }.joined(separator: " · ")
  }

  public static func recordID(host: String) -> UUID { DeterministicID.uuid("mac-agents/\(host)") }
}

public struct MacAgent: Codable, Equatable, Sendable, Identifiable {
  public let kind: AgentKind
  public let model: ModelKey?
  public let models: [ModelOption]

  public var id: AgentKind { kind }

  public init(kind: AgentKind, model: ModelKey?, models: [ModelOption]) {
    self.kind = kind
    self.model = model
    let missing = model.flatMap { key in models.contains { $0.key == key } ? nil : ModelOption(key: key, name: "", thinkingLevels: []) }
    self.models = (missing.map { [$0] } ?? []) + models
  }

  public var defaultModel: ModelOption? { model.flatMap { key in models.first { $0.key == key } } }
}

public struct MacAgentProblem: Codable, Equatable, Sendable {
  public let kind: AgentKind
  public let reason: Reason

  public init(kind: AgentKind, reason: Reason) {
    self.kind = kind
    self.reason = reason
  }

  public enum Reason: Equatable, Sendable, Codable, CustomStringConvertible {
    case notInstalled
    case notLoggedIn
    case other(ShownText)

    public var description: String {
      switch self {
      case .notInstalled: String(localized: "没装")
      case .notLoggedIn: String(localized: "没登录")
      case .other(let text): text.text
      }
    }
  }
}

extension MacAgents: Record, SyncedColumns {
  static let table = Table.macAgents
  static let fields: [Field] = [
    .plain("id"), .plain("hostID"), .encrypted("agents"), .encrypted("problems"), .plain("modifiedAt"), .encrypted("name"),
  ]
  var bindings: [any SQLBindable] {
    [Self.recordID(host: hostID), hostID, JSONColumn.encodeList(agents), JSONColumn.encodeList(problems), modifiedAt, name]
  }
  init(row: Row) {
    self.init(
      hostID: row.text(1), name: row.textOrNil(5), agents: JSONColumn.decodeList(Lenient<MacAgent>.self, from: row.textOrNil(2)).compactMap(\.value),
      problems: JSONColumn.decodeList(Lenient<MacAgentProblem>.self, from: row.textOrNil(3)).compactMap(\.value),
      modifiedAt: row.date(4))
  }
}

extension CueStore {
  public func recordMacAgents(host: String, name: String?, _ agents: [MacAgent], problems: [MacAgentProblem] = []) throws {
    try write {
      if let stored = try find(MacAgents.self, MacAgents.recordID(host: host)), stored.name == name, stored.agents == agents, stored.problems == problems {
        return
      }
      let record = MacAgents(hostID: host, name: name, agents: agents, problems: problems, modifiedAt: Date.stamp)
      try upsert(record, updating: ["name", "agents", "problems", "modifiedAt"])
    }
  }

  public func allMacAgents() throws -> [MacAgents] {
    try select(MacAgents.self, orderBy: "name, hostID")
  }

  public func macAgents(on host: String) throws -> MacAgents {
    try find(MacAgents.self, MacAgents.recordID(host: host)) ?? MacAgents(hostID: host, agents: [], modifiedAt: .distantPast)
  }
}
