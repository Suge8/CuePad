import Foundation

/// 按内容定 id：报的一样的会话共用一条，不一样的各有一条，谁也不覆盖谁。取值取决于的东西不止 Mac、Agent 与工作目录（Pi 的命令含工作目录 `.pi/` 下的技能、提示词模板与扩展，模型范围也来自项目设置与单个进程的 `--models`）。
/// 一条写下就不再改，不随会话状态的每次变化上传（模型清单可达几十 KB）。会话结束、进程不在了也留着：发话、换模型会在后台唤醒它，回复框照这份列模型与命令。
public struct AgentCatalog: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var hostID: String
  public var models: [PiModelOption]
  public var commands: [PiSlashCommand]
  public var modifiedAt: Date

  public init(id: UUID, hostID: String, models: [PiModelOption], commands: [PiSlashCommand], modifiedAt: Date) {
    self.id = id
    self.hostID = hostID
    self.models = models
    self.commands = commands
    self.modifiedAt = modifiedAt
  }

  /// 带上主机：回收只动本机写的。
  public static func recordID(host: String, models: [PiModelOption], commands: [PiSlashCommand]) -> UUID {
    DeterministicID.uuid("agent-catalog/\(host)/\(JSONColumn.encode(models))/\(JSONColumn.encode(commands))")
  }

  public init(host: String, models: [PiModelOption], commands: [PiSlashCommand], at now: Date) {
    self.init(id: Self.recordID(host: host, models: models, commands: commands), hostID: host, models: models, commands: commands, modifiedAt: now)
  }
}

extension AgentCatalog: Record {
  static let table = Table.agentCatalogs
  static let columns = ["id", "hostID", "models", "commands", "modifiedAt"]
  var bindings: [any SQLBindable] { [id, hostID, JSONColumn.encodeList(models), JSONColumn.encodeList(commands), modifiedAt] }
  init(row: Row) {
    self.init(
      id: row.uuid(0), hostID: row.text(1), models: JSONColumn.decodeList(PiModelOption.self, from: row.textOrNil(2)),
      commands: JSONColumn.decodeList(PiSlashCommand.self, from: row.textOrNil(3)), modifiedAt: row.date(4))
  }
}

extension CueStore {
  public func agentCatalog(_ id: UUID) throws -> AgentCatalog? { try find(AgentCatalog.self, id) }

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
