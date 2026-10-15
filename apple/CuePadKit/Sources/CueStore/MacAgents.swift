import Foundation

/// 一台 Mac 上的 Agent 能不能用、各家的模型（同步表 `macAgents`，每台 Mac 一条，只由它自己写；各端只读）：
/// 开新会话能选哪几家、默认哪家、Cue 的大脑能选哪几家哪些模型、不指定模型时实际用哪个、一家都不能用时为什么，两端都只从这里推出。
/// 能用 = 装着、接入了（`AgentStatus.canLaunch`），并且问得出它的模型（登录了）；探测与写的时机在 App 的 Mac 端。
/// 内容没变不写（不触发同步）。没有记录（还没探测完，或更旧版本的 Mac）是一家都不能用。
public struct MacAgents: Equatable, Sendable {
  public var hostID: String
  /// 能用的，按 `AgentKind` 的顺序；更新的版本写的、不认识的那家读出时丢掉（下同）。
  public var agents: [MacAgent]
  /// 不能用的与原因（没装、没接入、没登录、问不出），按 `AgentKind` 的顺序。
  public var problems: [MacAgentProblem]
  public var modifiedAt: Date

  public init(hostID: String, agents: [MacAgent], problems: [MacAgentProblem] = [], modifiedAt: Date) {
    self.hostID = hostID
    self.agents = agents
    self.problems = problems
    self.modifiedAt = modifiedAt
  }

  public func agent(_ kind: AgentKind) -> MacAgent? { agents.first { $0.kind == kind } }

  public var kinds: [AgentKind] { agents.map(\.kind) }

  /// 开新会话默认用哪家：上次用的（`last`）这台还能用就是它，否则第一家；一家都不能用为 nil。
  public func preferred(_ last: AgentKind) -> AgentKind? { kinds.contains(last) ? last : kinds.first }

  /// 一家都不能用时为什么（"Pi 没登录 · Codex 没装"）；还没有这台 Mac 写的记录时说还没查过。
  public var whyNone: String {
    problems.isEmpty ? "还没查过有哪些 Agent 能用" : problems.map { "\($0.kind.name) \($0.reason)" }.joined(separator: " · ")
  }

  public static func recordID(host: String) -> UUID { DeterministicID.uuid("mac-agents/\(host)") }
}

/// 一家 Agent 在一台 Mac 上：不指定模型时它用哪个（`model`，Agent 自己按它的配置定的那个），能选哪些（`models`，与它在会话里报的
/// 模型菜单同一规则：Pi 配了范围就是范围内的）。默认的总在清单里：没报在清单里的补在最前，菜单才选得回"跟着默认"。
/// 没有模型清单的（OpenCode）两者都空。
public struct MacAgent: Codable, Equatable, Sendable, Identifiable {
  public let kind: AgentKind
  public let model: PiModelKey?
  public let models: [PiModelOption]

  public var id: AgentKind { kind }

  public init(kind: AgentKind, model: PiModelKey?, models: [PiModelOption]) {
    self.kind = kind
    self.model = model
    let missing = model.flatMap { key in models.contains { $0.key == key } ? nil : PiModelOption(key: key, name: "", thinkingLevels: []) }
    self.models = (missing.map { [$0] } ?? []) + models
  }

  /// 不指定模型时用的那一项。
  public var defaultModel: PiModelOption? { model.flatMap { key in models.first { $0.key == key } } }
}

/// 一家不能用的原因（给人看的短语，接在 Agent 名后面）。
public struct MacAgentProblem: Codable, Equatable, Sendable {
  public let kind: AgentKind
  public let reason: String

  public init(kind: AgentKind, reason: String) {
    self.kind = kind
    self.reason = reason
  }
}

/// 读出时跳过不认识的那家（更新的版本加的 Agent），其余照读。
private struct Lenient<T: Decodable>: Decodable {
  let value: T?
  init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}

extension MacAgents: Record {
  static let table = Table.macAgents
  static let columns = ["id", "hostID", "agents", "problems", "modifiedAt"]
  var bindings: [any SQLBindable] {
    [Self.recordID(host: hostID), hostID, JSONColumn.encodeList(agents), JSONColumn.encodeList(problems), modifiedAt]
  }
  init(row: Row) {
    self.init(
      hostID: row.text(1), agents: JSONColumn.decodeList(Lenient<MacAgent>.self, from: row.textOrNil(2)).compactMap(\.value),
      problems: JSONColumn.decodeList(Lenient<MacAgentProblem>.self, from: row.textOrNil(3)).compactMap(\.value),
      modifiedAt: row.date(4))
  }
}

extension CueStore {
  /// 这台 Mac 写下自己的 Agent 能不能用；和库里的一样就不写。返回写了的记录 id（立即上传用），没写为 nil。
  @discardableResult
  public func recordMacAgents(host: String, _ agents: [MacAgent], problems: [MacAgentProblem] = []) throws -> UUID? {
    try write {
      if let stored = try find(MacAgents.self, MacAgents.recordID(host: host)), stored.agents == agents, stored.problems == problems { return nil }
      let record = MacAgents(hostID: host, agents: agents, problems: problems, modifiedAt: Date.stamp)
      try db.run(
        """
        INSERT INTO macAgents (\(MacAgents.columns.joined(separator: ", "))) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET agents = excluded.agents, problems = excluded.problems, modifiedAt = excluded.modifiedAt
        """, record.bindings)
      return MacAgents.recordID(host: host)
    }
  }

  /// 那台 Mac 上的 Agent；没有记录是一家都没有（`whyNone` 说还没查过）。
  public func macAgents(on host: String) throws -> MacAgents {
    try find(MacAgents.self, MacAgents.recordID(host: host)) ?? MacAgents(hostID: host, agents: [], modifiedAt: .distantPast)
  }
}
