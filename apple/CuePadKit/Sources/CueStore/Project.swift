import Foundation

public struct Project: Identifiable, Equatable, Sendable {
  public let id: UUID
  /// 不会是空的：写入时空名抛 `blankProjectName`；别处（旧版本、同步）留下的空名读出来是 `untitled`。
  public var name: String
  public var icon: String?
  public var color: String
  public var isPinned: Bool
  /// 可选的一句话介绍（项目页顶栏、书架项目卡）。
  public var intro: String?
  /// 回收站中的项目；其卡片随之进回收站（由项目推导，卡片自身不记）。
  public internal(set) var deletedAt: Date?
  public var createdAt: Date
  public var modifiedAt: Date

  public static let untitled = "未命名项目"

  /// 默认项目：每个库都有、不能删（`trashProject` 拒绝），没指定项目记下的灵感与任务都进它。id 在所有设备上同一个，
  /// 离线时两台各自建出来也合成一条；建出来的那版修改时间是 0（`Schema.defaultProject`），用户改过名、颜色的总比它新。
  public static let defaultID = DeterministicID.uuid("project/default")
  public var isDefault: Bool { id == Self.defaultID }
}

/// 项目的灵感数（散放在列表里的，不含任务、挂在任务下的与空白灵感）。
public struct ProjectSummary: Equatable, Sendable {
  public var projectID: UUID
  public var cardCount: Int
}

extension Project: Record {
  static let table = Table.projects
  static let columns = ["id", "name", "icon", "color", "isPinned", "deletedAt", "createdAt", "modifiedAt", "intro"]
  var bindings: [any SQLBindable] { [id, name, icon, color, isPinned, deletedAt, createdAt, modifiedAt, intro] }
  init(row: Row) {
    self.init(
      id: row.uuid(0), name: row.text(1).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Project.untitled : row.text(1),
      icon: row.textOrNil(2), color: row.text(3),
      isPinned: row.bool(4), intro: row.textOrNil(8),
      deletedAt: row.dateOrNil(5), createdAt: row.date(6), modifiedAt: row.date(7))
  }
}
