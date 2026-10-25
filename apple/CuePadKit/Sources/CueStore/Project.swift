import Foundation

public struct Project: Identifiable, Equatable, Sendable {
  public let id: UUID
  /// 库里存的名字（Cue、命令行与同步看的都是它）；界面显示读 `shownName`。写入时空名抛 `blankProjectName`，别处（旧版本、同步）可能留下空名。
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

  public static var untitled: String { String(localized: "未命名项目") }

  /// 默认项目：每个库都有、不能删（`trashProject` 拒绝），没指定项目记下的灵感与任务都进它。id 在所有设备上同一个，
  /// 离线时两台各自建出来也合成一条；建出来的那版修改时间是 0（`Schema.defaultProject`），用户改过名、颜色的总比它新。
  public static let defaultID = DeterministicID.uuid("project/default")
  public var isDefault: Bool { id == Self.defaultID }

  /// 建库时默认项目的名字（`Schema.defaultProject`）：库里存、同步的都是这一份，各台设备离线建出的才是同一版。
  static let defaultName = "默认"

  /// 给人看的名字（界面上写项目都读它）：没改过名的默认项目按这台设备的语言写，空名写 `untitled`，别的照存的。
  public var shownName: String { Self.shownName(id: id, name: name) }

  public static func shownName(id: UUID, name: String) -> String {
    if id == defaultID && name == defaultName { return String(localized: "默认") }
    return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? untitled : name
  }
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
      id: row.uuid(0), name: row.text(1), icon: row.textOrNil(2), color: row.text(3),
      isPinned: row.bool(4), intro: row.textOrNil(8),
      deletedAt: row.dateOrNil(5), createdAt: row.date(6), modifiedAt: row.date(7))
  }
}
