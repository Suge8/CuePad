import Foundation

public struct ImportCounts: Equatable, Sendable {
  public var projects = 0
  public var cards = 0
  public var tasks = 0

  public init(projects: Int = 0, cards: Int = 0, tasks: Int = 0) {
    self.projects = projects
    self.cards = cards
    self.tasks = tasks
  }
}

public struct ImportReport: Equatable, Sendable {
  /// 旧库里读到的行数。
  public var found: ImportCounts
  /// 本次新写入的行数；已导入过的行不重复写、也不覆盖之后的修改。
  public var inserted: ImportCounts
  /// 旧库 app_settings 原文（JSON 文本）。主题、全局快捷键属于设备本地偏好，由 App 决定如何写入 UserDefaults。
  public var legacySettings: [String: String]
}

extension CueStore {
  /// 导入 Electron 版 SQLite 库。幂等：旧行 id 映射为确定的 UUID，已存在的行跳过。
  /// 只读取源库的副本（含 -wal），源文件从不被打开或修改。
  /// 映射：整数 id → UUID；sort_order → 分数索引；置顶（旧版卡片叫收藏）/任务完成时间照搬（项目顺序与卡片编号不导入）；卡片标题并入正文首行；标签不导入（产品不做标签）；
  /// 单独删除的卡保留 deletedAt，随项目删除的卡由项目推导；旧库不存变量取值（原在 localStorage），不导入。
  public func importElectronLibrary(from source: URL) throws -> ImportReport {
    let library = try LegacyLibrary(copyingFrom: source)
    return try write { try library.write(to: self) }
  }
}

/// 旧库内容，已转换为新模型行。
struct LegacyLibrary {
  var projects: [Project] = []
  var cards: [Card] = []
  var tasks: [Card] = []
  var settings: [String: String] = [:]

  init(copyingFrom source: URL) throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "cuepad-import-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // 只复制 db 与 wal：shm 是可重建的共享内存索引，复制活库的 shm 可能不一致。
    let copy = directory.appending(path: "cuepad.db")
    try FileManager.default.copyItem(at: source, to: copy)
    let wal = URL(filePath: source.path + "-wal")
    if FileManager.default.fileExists(atPath: wal.path) {
      try FileManager.default.copyItem(at: wal, to: URL(filePath: copy.path + "-wal"))
    }
    try load(SQLite(path: copy.path))
  }

  private mutating func load(_ legacy: SQLite) throws {
    let projectRows = try legacy.query("SELECT * FROM projects ORDER BY sort_order, id", [], LegacyRow.init)
    let trashedProjects = Set(projectRows.filter { $0.deletedAt != nil }.map(\.id))
    projects = projectRows.map { row in
      Project(
        id: LegacyID.uuid("project", row.id), name: row.name ?? "", icon: row.icon, color: row.color,
        isPinned: row.flag, intro: nil, deletedAt: row.deletedAt,
        createdAt: row.createdAt, modifiedAt: row.updatedAt)
    }

    let cardRows = try legacy.query("SELECT * FROM cards ORDER BY sort_order, id", [], LegacyRow.init)
    cards = zip(cardRows, SortKey.sequence(count: cardRows.count)).map { row, key in
      // 随项目删除的卡由项目推导；只有单独删除的卡自带 deletedAt。
      let followsProject = row.deleteSource == "project" && row.projectID.map(trashedProjects.contains) == true
      return Card(
        id: LegacyID.uuid("card", row.id), projectID: row.projectID.map { LegacyID.uuid("project", $0) },
        body: [row.title, row.body].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n"),
        isPinned: row.flag,
        variableValues: [:], conflictOf: nil, sortKey: key, deletedAt: followsProject ? nil : row.deletedAt,
        createdAt: row.createdAt, modifiedAt: row.updatedAt)
    }

    let taskRows = try legacy.query("SELECT * FROM tasks ORDER BY sort_order, id", [], LegacyRow.init)
    tasks = zip(taskRows, SortKey.sequence(count: taskRows.count)).map { row, key in
      Card(
        id: LegacyID.uuid("task", row.id), projectID: row.projectID.map { LegacyID.uuid("project", $0) }, body: row.content ?? "",
        isPinned: false, variableValues: [:], conflictOf: nil, sortKey: key, deletedAt: nil, createdAt: row.createdAt,
        modifiedAt: row.updatedAt, todoAt: row.createdAt, completedAt: row.completedAt)
    }

    for (key, value) in try legacy.query("SELECT key, value FROM app_settings", [], { ($0.text(0), $0.text(1)) }) {
      settings[key] = value
    }
  }

  func write(to store: isolated CueStore) throws -> ImportReport {
    var inserted = ImportCounts()
    for row in projects where try store.insert(row, ignoringExisting: true) { inserted.projects += 1 }
    for row in cards where try store.insert(row, ignoringExisting: true) { inserted.cards += 1 }
    for row in tasks where try store.insert(row, ignoringExisting: true) { inserted.tasks += 1 }
    return ImportReport(
      found: ImportCounts(
        projects: projects.count, cards: cards.count, tasks: tasks.count),
      inserted: inserted, legacySettings: settings)
  }
}

/// 旧库各表的统一读取视图：`SELECT *` 后按列名取值，表里没有的列为 nil。
private struct LegacyRow {
  let id: Int64
  let projectID: Int64?
  let name: String?
  let title: String?
  let body: String?
  let content: String?
  let icon: String?
  let color: String
  let deleteSource: String?
  let flag: Bool
  let deletedAt: Date?
  let completedAt: Date?
  let createdAt: Date
  let updatedAt: Date

  init(_ row: Row) {
    func int(_ name: String) -> Int64? { row.index(of: name).flatMap(row.intOrNil) }
    func text(_ name: String) -> String? { row.index(of: name).flatMap(row.textOrNil) }
    func date(_ name: String) -> Date? { int(name).map { Date(timeIntervalSince1970: Double($0) / 1000) } }
    id = int("id") ?? 0
    projectID = int("project_id")
    name = text("name")
    title = text("title")
    body = text("body")
    content = text("content")
    icon = text("icon")
    color = text("color") ?? ""
    deleteSource = text("delete_source")
    flag = (int("is_pinned") ?? int("is_favorite")) == 1
    deletedAt = date("deleted_at")
    completedAt = date("completed_at")
    createdAt = date("created_at") ?? Date()
    updatedAt = date("updated_at") ?? createdAt
  }
}

/// 旧整数 id → 确定的 UUID，重复导入得到同一批 id。
private enum LegacyID {
  static func uuid(_ kind: String, _ id: Int64) -> UUID { uuid(kind, String(id)) }
  static func uuid(_ kind: String, _ key: String) -> UUID { DeterministicID.uuid("electron/\(kind)/\(key)") }
}
