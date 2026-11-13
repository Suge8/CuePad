import Foundation

/// 按内容定 id：报的一样的会话共用一条，不一样的各有一条，谁也不覆盖谁。取值取决于的东西不止 Mac、Agent 与工作目录（Pi 的命令含工作目录 `.pi/` 下的技能、提示词模板与扩展，模型范围也来自项目设置与单个进程的 `--models`）。
/// 一条写下就不再改，不随会话状态的每次变化上传（模型清单可达几十 KB）。会话结束、进程不在了也留着：发话、换模型会在后台唤醒它，回复框照这份列模型与命令。
public struct AgentCatalog: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var hostID: String
  public var models: [ModelOption]
  public var commands: [SlashCommand]
  public var modifiedAt: Date

  public init(id: UUID, hostID: String, models: [ModelOption], commands: [SlashCommand], modifiedAt: Date) {
    self.id = id
    self.hostID = hostID
    self.models = models
    self.commands = commands
    self.modifiedAt = modifiedAt
  }

  /// 带上主机：回收只动本机写的。
  public static func recordID(host: String, models: [ModelOption], commands: [SlashCommand]) -> UUID {
    DeterministicID.uuid("agent-catalog/\(host)/\(JSONColumn.encode(models))/\(JSONColumn.encode(commands))")
  }

  public init(host: String, models: [ModelOption], commands: [SlashCommand], at now: Date) {
    self.init(id: Self.recordID(host: host, models: models, commands: commands), hostID: host, models: models, commands: commands, modifiedAt: now)
  }
}

extension AgentCatalog: Record {
  static let table = Table.agentCatalogs
  static let columns = ["id", "hostID", "models", "commands", "modifiedAt"]
  var bindings: [any SQLBindable] { [id, hostID, JSONColumn.encodeList(models), JSONColumn.encodeList(commands), modifiedAt] }
  init(row: Row) {
    self.init(
      id: row.uuid(0), hostID: row.text(1), models: JSONColumn.decodeList(ModelOption.self, from: row.textOrNil(2)),
      commands: JSONColumn.decodeList(SlashCommand.self, from: row.textOrNil(3)), modifiedAt: row.date(4))
  }
}

extension CueStore {
  public func agentCatalog(_ id: UUID) throws -> AgentCatalog? { try find(AgentCatalog.self, id) }

  /// 一个会话能选的模型与能用的命令，读的只此一处：它报过就是它那份；没报过的（只从会话文件索引来、没连过桥的）是它那台 Mac 上这一家
  /// 此刻的模型（`MacAgents`），没有命令。回复框据此对每个会话都列得出模型，不看它的进程在不在、是谁开的。
  public func catalog(of session: SessionState) throws -> AgentCatalog? {
    if let own = try session.catalogID.flatMap(agentCatalog) { return own }
    let host = try macAgents(on: session.hostID)
    guard let models = session.agent.known.flatMap({ host.agent($0) })?.models, !models.isEmpty else { return nil }
    return AgentCatalog(host: session.hostID, models: models, commands: [], at: host.modifiedAt)
  }

  /// 会话没记下模型（桥没报过、会话文件里也没有）时接着说会用的：它那台 Mac 上这一家的默认。
  public func defaultModel(of session: SessionState) throws -> ModelOption? {
    try session.agent.known.flatMap { try macAgents(on: session.hostID).agent($0) }?.defaultModel
  }

  func writeCatalog(_ catalog: AgentCatalog) throws {
    _ = try insert(catalog, ignoringExisting: true)
  }

  /// 只动本机的：别的 Mac 的会话记录可能还在路上。
  func dropUnusedCatalogs(host: String) throws {
    try db.run(
      "DELETE FROM agentCatalogs WHERE hostID = ? AND NOT EXISTS (SELECT 1 FROM piSessionStates s WHERE s.catalogID = agentCatalogs.id)",
      [host])
  }
}
