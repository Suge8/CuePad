import Foundation

/// 一台 Mac 上的会话可换的模型与能用的斜杠命令（同步记录，Mac 写、各端读；会话记录只记它的 id，`PiSessionState.catalogID`）。
/// 取值取决于的东西不止 Mac、Agent 与工作目录（Pi 的命令含工作目录 `.pi/` 下的技能、提示词模板与扩展，模型范围来自项目设置的
/// `enabledModels`，也来自单个进程的 `--models`，当前模型不在范围内时还把它列上），所以按内容定 id：报的一样的会话共用一条，
/// 不一样的各有一条，谁也不覆盖谁。一条写下就不再改；会话报的变了就指向另一条。不随会话状态的每次变化上传（模型清单可达几十 KB）。
/// 没有会话再指向它时由写它的 Mac 删掉（`CueStore.dropUnusedCatalogs`）。
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

  /// 内容相同的得到同一个 id（任何设备上都一样）；带上主机：回收只动本机写的。
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

  /// 写下这一份；已有（id 即内容）就不写（不触发同步）。
  func writeCatalog(_ catalog: AgentCatalog) throws {
    _ = try insert(catalog, ignoringExisting: true)
  }

  /// 进程不在了的会话（`condition` 选出的）不再能换模型、命令还认：指向换成只有命令的那一份（没有命令就不指向），
  /// 原来那份没人用了由 `dropUnusedCatalogs` 回收。
  func dropCatalogModels(where condition: String, _ arguments: [any SQLBindable], at now: Date) throws {
    let pointed = try db.query(
      "SELECT DISTINCT catalogID FROM piSessionStates WHERE catalogID IS NOT NULL AND \(condition)", arguments) { $0.uuid(0) }
    for id in pointed {
      guard let full = try agentCatalog(id), !full.models.isEmpty else { continue }
      let kept = full.commands.isEmpty ? nil : AgentCatalog(host: full.hostID, models: [], commands: full.commands, at: now)
      if let kept { try writeCatalog(kept) }
      try db.run("UPDATE piSessionStates SET catalogID = ? WHERE catalogID = ? AND \(condition)", [kept?.id, id] + arguments)
    }
  }

  /// 删掉这台 Mac 写的、已没有会话记录指向的目录记录（同步删除）。只动本机的：别的 Mac 的会话记录可能还在路上。
  func dropUnusedCatalogs(host: String) throws {
    try db.run(
      "DELETE FROM agentCatalogs WHERE hostID = ? AND NOT EXISTS (SELECT 1 FROM piSessionStates s WHERE s.catalogID = agentCatalogs.id)",
      [host])
  }
}
