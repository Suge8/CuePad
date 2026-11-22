import Foundation

public enum MissingProject: Sendable {
  case reject, useDefault
}

public struct Project: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var icon: String?
  public var color: String
  public var isPinned: Bool
  public var intro: String?
  public internal(set) var deletedAt: Date?
  public var createdAt: Date
  public var modifiedAt: Date

  public static var untitled: String { String(localized: "未命名项目") }

  public static let defaultID = DeterministicID.uuid("project/default")
  public var isDefault: Bool { id == Self.defaultID }

  public static let defaultName = "默认"

  public var shownName: String { Self.shownName(id: id, name: name) }

  public static func shownName(id: UUID, name: String) -> String {
    if id == defaultID && name == defaultName { return defaultShownName }
    return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? untitled : name
  }

  private static var defaultShownName: String { String(localized: "默认") }

  static func nameMatch(_ text: String, stored: String, id: String = "id", name: String = "name") -> (sql: String, arguments: [any SQLBindable]) {
    var sql = stored
    var arguments: [any SQLBindable] = []
    if defaultShownName.localizedCaseInsensitiveContains(text) {
      sql += " OR (\(id) = ? AND \(name) = ?)"
      arguments += [defaultID, defaultName]
    }
    if untitled.localizedCaseInsensitiveContains(text) { sql += " OR trim(\(name)) = ''" }
    return ("(\(sql))", arguments)
  }
}

public struct ProjectSummary: Equatable, Sendable {
  public var projectID: UUID
  public var cardCount: Int
  public var modifiedAt: Date
}

extension Project: Record, SyncedColumns {
  static let table = Table.projects
  static let fields: [Field] = [
    .plain("id"), .encrypted("name"), .plain("icon"), .plain("color"), .plain("isPinned"), .plain("deletedAt"), .plain("createdAt"),
    .plain("modifiedAt"), .plain("intro"),
  ]
  var bindings: [any SQLBindable] { [id, name, icon, color, isPinned, deletedAt, createdAt, modifiedAt, intro] }
  init(row: Row) {
    self.init(
      id: row.uuid(0), name: row.text(1), icon: row.textOrNil(2), color: row.text(3),
      isPinned: row.bool(4), intro: row.textOrNil(8),
      deletedAt: row.dateOrNil(5), createdAt: row.date(6), modifiedAt: row.date(7))
  }
}
