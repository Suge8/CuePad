import Foundation

/// 技能与规则里一份文件的正文（同步表 `agentLibraryFiles`，那台 Mac 每份文件一条、只由它写，键是 Mac 加文件路径）：
/// 技能的 SKILL.md、各份规则、合并要比的各家那几份（`InstructionSource.path`）。快照（`AgentLibrary`）里只有它们的哈希；
/// 列表上的全局规则预览、文件页、合并稿都读这一条，手机打开文件页就读本地已同步来的这条，不向 Mac 要。
/// Mac 每次重读只写内容变了的，删掉已不在的（`CueStore.recordAgentLibrary`）。
/// 快照与正文分两条传，手机上可能先到快照：哈希对不上本地这条时，这条还在路上（文件页等它到了再载入）。
public struct LibraryFileText: Equatable, Sendable {
  public var hostID: String
  /// 文件的绝对路径（技能是它的 SKILL.md，`LibrarySkill.textPath`）
  public var path: String
  public var text: String
  public var modifiedAt: Date

  public init(hostID: String, path: String, text: String, modifiedAt: Date) {
    self.hostID = hostID
    self.path = path
    self.text = text
    self.modifiedAt = modifiedAt
  }

  public var hash: String { LibraryEdit.base(of: text) }

  public static func recordID(host: String, path: String) -> UUID { DeterministicID.uuid("agent-library-file/\(host)/\(path)") }
}

extension LibraryFileText: Record {
  static let table = Table.agentLibraryFiles
  static let columns = ["id", "hostID", "path", "hash", "text", "modifiedAt"]
  var bindings: [any SQLBindable] { [Self.recordID(host: hostID, path: path), hostID, path, hash, text, modifiedAt] }
  init(row: Row) {
    self.init(hostID: row.text(1), path: row.text(2), text: row.text(4), modifiedAt: row.date(5))
  }
}

extension CueStore {
  /// 这台 Mac 写下自己的技能与规则：快照（`modifiedAt` 不看，和库里的一样就不写）与各份文件的正文（`texts`，路径 → 正文；
  /// 只写内容变了的，这台的、不在 `texts` 里的删掉），同一个事务。返回写了与删了的记录 id（立即上传用）。
  @discardableResult
  public func recordAgentLibrary(_ library: AgentLibrary, texts: [String: String]) throws -> [UUID] {
    try write {
      let host = library.hostID
      var changed: [UUID] = []
      if try find(AgentLibrary.self, AgentLibrary.recordID(host: host))?.sameContent(as: library) != true {
        var record = library
        record.modifiedAt = Date.stamp
        try upsert(record)
        changed.append(AgentLibrary.recordID(host: host))
      }
      let stored = Dictionary(
        uniqueKeysWithValues: try db.query("SELECT path, hash FROM agentLibraryFiles WHERE hostID = ?", [host]) { ($0.text(0), $0.text(1)) })
      for (path, text) in texts where stored[path] != LibraryEdit.base(of: text) {
        try upsert(LibraryFileText(hostID: host, path: path, text: text, modifiedAt: Date.stamp))
        changed.append(LibraryFileText.recordID(host: host, path: path))
      }
      for path in stored.keys where texts[path] == nil {
        let id = LibraryFileText.recordID(host: host, path: path)
        try db.run("DELETE FROM agentLibraryFiles WHERE id = ?", [id])
        changed.append(id)
      }
      return changed
    }
  }

  /// 要看的那台 Mac 的技能与规则：Mac 上 `host` 给本机，只认它（还没扫完、碰不得 `~/.agents` 时为 nil，不拿别台的充数）；
  /// 手机上给 nil，看 Cue 运行的那台，那台没写过就是最近写过的一台，一台都没写过为 nil。
  public func agentLibrary(host: String?) throws -> AgentLibrary? {
    if let host { return try find(AgentLibrary.self, AgentLibrary.recordID(host: host)) }
    if let cue = try cueProfile()?.hostID, let library = try find(AgentLibrary.self, AgentLibrary.recordID(host: cue)) { return library }
    return try select(AgentLibrary.self, orderBy: "modifiedAt DESC").first
  }

  /// `host` 那台 Mac 上这几份文件此刻同步来的正文（路径 → 正文）；还没到的不在里面。
  public func agentLibraryTexts(host: String, paths: [String]) throws -> [String: String] {
    let ids = JSONColumn.encode(paths.map { LibraryFileText.recordID(host: host, path: $0).uuidString.lowercased() })
    let rows = try select(LibraryFileText.self, where: "id IN (SELECT value FROM json_each(?))", [ids])
    return Dictionary(rows.map { ($0.path, $0.text) }, uniquingKeysWith: { a, _ in a })
  }
}
