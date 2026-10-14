import Foundation

/// 一台 Mac 上一种 Agent 在一个工作目录里可换的模型与能用的斜杠命令（同步记录，Mac 写、各端读；会话记录只记它的 id，`PiSessionState.catalogID`）。
/// 键是取值真正取决于的东西：Mac、Agent、工作目录。Pi 的命令含工作目录里 `.pi/` 下的技能、提示词模板与扩展，模型范围可由项目设置
/// （`.pi/settings.json` 的 `enabledModels`）限定；Claude Code、Codex 的命令含项目里的；OpenCode 的模型与命令都按目录取。
/// 同一目录里的会话取值相同，共用一条：内容变了才写，不随会话状态的每次变化上传（模型清单可达几十 KB）。
/// 完整路径不同步，只进 id 的散列。没有会话再指向它时由写它的 Mac 删掉（`CueStore.dropUnusedCatalogs`）。
/// 例外：Pi 的 `--models` 是单个进程的参数，当前模型不在范围内时 Pi 也把它列上；同一目录里这样的会话各报各的，以最后变的为准。
public struct AgentCatalog: Identifiable, Equatable, Sendable {
  public let id: UUID
  /// 写它的那台 Mac。
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

  /// 任何设备上算出来都一样；路径是会话的工作目录原样。
  public static func recordID(host: String, agent: AgentKind, directory: String) -> UUID {
    DeterministicID.uuid("agent-catalog/\(host)/\(agent.rawValue)/\(directory)")
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

  /// 写下这一份；和库里一样就不写（不触发同步）。
  func writeCatalog(_ catalog: AgentCatalog) throws {
    try db.run(
      """
      INSERT INTO agentCatalogs (\(AgentCatalog.columns.joined(separator: ", "))) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET models = excluded.models, commands = excluded.commands, modifiedAt = excluded.modifiedAt
      WHERE models IS NOT excluded.models OR commands IS NOT excluded.commands
      """, catalog.bindings)
  }

  /// 删掉这台 Mac 写的、已没有会话记录指向的目录记录（同步删除）。只动本机的：别的 Mac 的会话记录可能还在路上。
  func dropUnusedCatalogs(host: String) throws {
    try db.run(
      "DELETE FROM agentCatalogs WHERE hostID = ? AND NOT EXISTS (SELECT 1 FROM piSessionStates s WHERE s.catalogID = agentCatalogs.id)",
      [host])
  }
}
