import Foundation

/// 一台 Mac 上能用的 Agent 与各家的模型（同步表 `macAgents`，每台 Mac 一条，只由它自己写；各端只读）：
/// 开新会话能选哪几家、Cue 的大脑能选哪几家哪些模型、不指定模型时实际用哪个，两端都只从这里推出，界面不另列 Agent。
/// 能用 = 装着、接入了（`AgentStatus.canLaunch`），并且问得出它的模型（登录了）；探测与写的时机在 App 的 Mac 端。
/// 内容没变不写（不触发同步）。没有记录（还没探测完，或更旧版本的 Mac）是一家都不能用。
public struct MacAgents: Equatable, Sendable {
  public var hostID: String
  /// 按 `AgentKind` 的顺序；更新的版本写的、不认识的那家读出时丢掉。
  public var agents: [MacAgent]
  public var modifiedAt: Date

  public init(hostID: String, agents: [MacAgent], modifiedAt: Date) {
    self.hostID = hostID
    self.agents = agents
    self.modifiedAt = modifiedAt
  }

  public func agent(_ kind: AgentKind) -> MacAgent? { agents.first { $0.kind == kind } }

  public var kinds: [AgentKind] { agents.map(\.kind) }

  public static func recordID(host: String) -> UUID { DeterministicID.uuid("mac-agents/\(host)") }
}

/// 一家 Agent 在一台 Mac 上：不指定模型时它用哪个（`model`，Agent 自己按它的配置定的那个），能选哪些（`models`，与它在会话里报的
/// 模型菜单同一规则：Pi 配了范围就是范围内的）。没有模型清单的（OpenCode）两者都空。
public struct MacAgent: Codable, Equatable, Sendable, Identifiable {
  public var kind: AgentKind
  public var model: PiModelKey?
  public var models: [PiModelOption]

  public var id: AgentKind { kind }

  public init(kind: AgentKind, model: PiModelKey?, models: [PiModelOption]) {
    self.kind = kind
    self.model = model
    self.models = models
  }

  /// 不指定模型时用的那一项：清单里有就是它（带显示名与支持的强度），不在清单里只有 id。
  public var defaultModel: PiModelOption? {
    model.map { key in models.first { $0.key == key } ?? PiModelOption(key: key, name: "", thinkingLevels: []) }
  }
}

/// 读出时跳过不认识的那家（更新的版本加的 Agent），其余照读。
private struct Lenient<T: Decodable>: Decodable {
  let value: T?
  init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}

extension MacAgents: Record {
  static let table = Table.macAgents
  static let columns = ["id", "hostID", "agents", "modifiedAt"]
  var bindings: [any SQLBindable] { [Self.recordID(host: hostID), hostID, JSONColumn.encodeList(agents), modifiedAt] }
  init(row: Row) {
    self.init(
      hostID: row.text(1), agents: JSONColumn.decodeList(Lenient<MacAgent>.self, from: row.textOrNil(2)).compactMap(\.value),
      modifiedAt: row.date(3))
  }
}

extension CueStore {
  /// 这台 Mac 写下自己能用的 Agent；和库里的一样就不写。返回写了的记录 id（立即上传用），没写为 nil。
  @discardableResult
  public func recordMacAgents(host: String, _ agents: [MacAgent]) throws -> UUID? {
    try write {
      if let stored = try find(MacAgents.self, MacAgents.recordID(host: host)), stored.agents == agents { return nil }
      let record = MacAgents(hostID: host, agents: agents, modifiedAt: Date.stamp)
      try db.run(
        """
        INSERT INTO macAgents (\(MacAgents.columns.joined(separator: ", "))) VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET agents = excluded.agents, modifiedAt = excluded.modifiedAt
        """, record.bindings)
      return MacAgents.recordID(host: host)
    }
  }

  /// 那台 Mac 上能用的 Agent；没有记录是一家都没有。
  public func macAgents(on host: String) throws -> MacAgents {
    try find(MacAgents.self, MacAgents.recordID(host: host)) ?? MacAgents(hostID: host, agents: [], modifiedAt: .distantPast)
  }
}
