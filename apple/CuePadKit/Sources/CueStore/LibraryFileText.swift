import Foundation

public struct LibraryFileText: Equatable, Sendable {
  public var hostID: String
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

extension LibraryFileText: Record, SyncedColumns {
  static let table = Table.agentLibraryFiles
  static let fields: [Field] = [.plain("id"), .plain("hostID"), .encrypted("path"), .encrypted("hash"), .encrypted("text"), .plain("modifiedAt")]
  var bindings: [any SQLBindable] { [Self.recordID(host: hostID, path: path), hostID, path, hash, text, modifiedAt] }
  init(row: Row) {
    self.init(hostID: row.text(1), path: row.text(2), text: row.text(4), modifiedAt: row.date(5))
  }
}
