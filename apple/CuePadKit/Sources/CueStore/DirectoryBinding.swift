import Foundation

public struct DirectoryBinding: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var projectID: UUID
  public var hostID: String
  public var folder: String
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

extension DirectoryBinding: Record, SyncedColumns {
  static let table = Table.directoryBindings
  static let fields: [Field] = [.plain("id"), .plain("projectID"), .plain("hostID"), .encrypted("folder"), .plain("createdAt"), .plain("modifiedAt")]
  static let macNameSQL = MacAgents.nameSQL(host: "directoryBindings.hostID")
  static var selection: String { (columns + [macNameSQL]).joined(separator: ", ") }
  var bindings: [any SQLBindable] { [id, projectID, hostID, folder, createdAt, modifiedAt] }
  init(row: Row) {
    self.init(
      id: row.uuid(0), projectID: row.uuid(1), hostID: row.text(2), folder: row.text(3), macName: MacAgents.shownName(row.textOrNil(6)),
      createdAt: row.date(4), modifiedAt: row.date(5))
  }
}
