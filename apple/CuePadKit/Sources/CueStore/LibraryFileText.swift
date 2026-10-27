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
