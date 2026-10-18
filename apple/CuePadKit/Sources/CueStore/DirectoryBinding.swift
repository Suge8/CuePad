import Foundation

/// 项目在哪台 Mac 上绑定了代码目录（Mac 写、手机读）：每个 (项目, Mac) 一条，只有目录末段名，完整路径只在那台 Mac 本机。
/// 手机据此列出能开新会话的项目，并知道发给哪台 Mac。由 Mac 从本机的目录绑定推导（`CueStore.publishDirectoryBindings`）。
/// 那台 Mac 的名字不存在这里：读出时取自它报的（`macName`）。
public struct DirectoryBinding: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var projectID: UUID
  public var hostID: String
  public var folder: String
  /// 那台 Mac 给人看的名字（`MacAgents.shownName`，读出时取，不存不同步）。
  public var macName: String
  public var createdAt: Date
  public var modifiedAt: Date

  public init(id: UUID, projectID: UUID, hostID: String, folder: String, macName: String = MacAgents.unnamed, createdAt: Date, modifiedAt: Date
  ) {
    self.id = id
    self.projectID = projectID
    self.hostID = hostID
    self.folder = folder
    self.macName = macName
    self.createdAt = createdAt
    self.modifiedAt = modifiedAt
  }

  static func recordID(project: UUID, host: String) -> UUID { DeterministicID.uuid("directory-binding/\(project.uuidString.lowercased())/\(host)") }
}

extension DirectoryBinding: Record {
  static let table = Table.directoryBindings
  static let columns = ["id", "projectID", "hostID", "folder", "createdAt", "modifiedAt"]
  static let macNameSQL = MacAgents.nameSQL(host: "directoryBindings.hostID")
  static var selection: String { (columns + [macNameSQL]).joined(separator: ", ") }
  var bindings: [any SQLBindable] { [id, projectID, hostID, folder, createdAt, modifiedAt] }
  init(row: Row) {
    self.init(
      id: row.uuid(0), projectID: row.uuid(1), hostID: row.text(2), folder: row.text(3), macName: MacAgents.shownName(row.textOrNil(6)),
      createdAt: row.date(4), modifiedAt: row.date(5))
  }
}
