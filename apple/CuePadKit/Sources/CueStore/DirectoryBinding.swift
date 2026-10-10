import Foundation

/// 项目在哪台 Mac 上绑定了代码目录（Mac 写、手机读）：每个 (项目, Mac) 一条，只有目录末段名，完整路径只在那台 Mac 本机。
/// 手机据此列出能开新会话的项目，并知道发给哪台 Mac。由 Mac 从本机的目录绑定推导（`CueStore.publishDirectoryBindings`）。
public struct DirectoryBinding: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var projectID: UUID
  public var hostID: String
  /// 那台 Mac 的名字（给人选 Mac 时看）。
  public var hostName: String
  public var folder: String
  public var createdAt: Date
  public var modifiedAt: Date

  public init(id: UUID, projectID: UUID, hostID: String, hostName: String, folder: String, createdAt: Date, modifiedAt: Date) {
    self.id = id
    self.projectID = projectID
    self.hostID = hostID
    self.hostName = hostName
    self.folder = folder
    self.createdAt = createdAt
    self.modifiedAt = modifiedAt
  }

  static func recordID(project: UUID, host: String) -> UUID { DeterministicID.uuid("directory-binding/\(project.uuidString.lowercased())/\(host)") }
}

extension DirectoryBinding: Record {
  static let table = Table.directoryBindings
  static let columns = ["id", "projectID", "hostID", "hostName", "folder", "createdAt", "modifiedAt"]
  var bindings: [any SQLBindable] { [id, projectID, hostID, hostName, folder, createdAt, modifiedAt] }
  init(row: Row) {
    self.init(
      id: row.uuid(0), projectID: row.uuid(1), hostID: row.text(2), hostName: row.text(3), folder: row.text(4),
      createdAt: row.date(5), modifiedAt: row.date(6))
  }
}
