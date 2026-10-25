import Foundation

extension CueStore {
  public func createProject(
    name: String, color: String, icon: String? = nil
  ) throws -> Project {
    try Self.requireName(name)
    return try write {
      let now = Date.stamp
      let project = Project(
        id: UUID(), name: name, icon: icon, color: color,
        isPinned: false, intro: nil, deletedAt: nil, createdAt: now, modifiedAt: now)
      try insert(project)
      return project
    }
  }

  /// 改名称、介绍、颜色、图标、置顶。删除状态对调用方只读，有专门的方法（编译期保证）。改了名的不能改成空名（别处留下的空名不改名照样能改别的）。
  public func updateProject(_ id: UUID, _ edit: @Sendable (inout Project) -> Void) throws {
    try write {
      guard var project = try find(Project.self, id) else { throw CueStoreError.notFound }
      let name = project.name
      edit(&project)
      if project.name != name { try Self.requireName(project.name) }
      project.modifiedAt = Date.stamp
      try update(project)
    }
  }

  private static func requireName(_ name: String) throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CueStoreError.blankProjectName }
  }

  /// 进回收站；它的卡片随之隐藏（由项目推导），卡片行不动。默认项目不能删（`defaultProjectUndeletable`）。
  public func trashProject(_ id: UUID) throws {
    guard id != Project.defaultID else { throw CueStoreError.defaultProjectUndeletable }
    try write {
      try db.run(
        "UPDATE projects SET deletedAt = ?1, modifiedAt = ?1 WHERE id = ?2 AND deletedAt IS NULL",
        [Date.stamp, id])
    }
  }

  public func restoreProject(_ id: UUID) throws {
    try write {
      try db.run("UPDATE projects SET deletedAt = NULL, modifiedAt = ? WHERE id = ?", [Date.stamp, id])
    }
  }

  /// 永久删除：连同随项目进回收站的卡片；更早单独进回收站的卡片留在回收站（归入默认项目）。
  public func purgeProject(_ id: UUID) throws {
    try reportingFileFailures { try write {
      let now = Date.stamp
      let orphaned = try purgeCards(where: "projectID = ? AND deletedAt IS NULL", [id])
      try db.run("UPDATE cards SET projectID = ?, modifiedAt = ? WHERE projectID = ?", [Project.defaultID, now, id])
      try db.run("DELETE FROM projectDirectories WHERE projectID = ?", [id])
      try db.run("DELETE FROM projects WHERE id = ?", [id])
      return try reclaimAttachments(orphaned)
    } }
  }

  /// 绑定项目的文件夹（nil = 解除）。目录因设备而异，不同步。会话归哪个项目写在会话记录上（写入时按绑定定），
  /// 所以绑定变了、同一个事务里把本机已有的会话（含历史）按新的绑定重新归：只改归属变了的，没变的不重写。
  public func setDirectory(_ directory: String?, for project: UUID) throws {
    try write {
      if let directory {
        try db.run(
          """
          INSERT INTO projectDirectories (projectID, directory) VALUES (?, ?)
          ON CONFLICT(projectID) DO UPDATE SET directory = excluded.directory
          """, [project, directory])
      } else {
        try db.run("DELETE FROM projectDirectories WHERE projectID = ?", [project])
      }
      try reassignSessions()
    }
  }

  /// 本机会话索引里的会话各按它的工作目录重新归项目（同一目录只算一次）。必须在写事务内调用。
  private func reassignSessions() throws {
    let directories = try db.query("SELECT DISTINCT cwd FROM piSessions") { $0.text(0) }
    let now = Date.stamp
    let bound = try boundDirectories()
    for cwd in directories {
      let project = cwd.isEmpty ? nil : Self.projectID(containing: URL(filePath: cwd, directoryHint: .isDirectory), in: bound)
      try db.run(
        """
        UPDATE piSessionStates SET projectID = ?, modifiedAt = ?
        WHERE sessionID IN (SELECT id FROM piSessions WHERE cwd = ?) AND projectID IS NOT ?
        """, [project, now, cwd, project])
    }
  }

  public func directory(of project: UUID) throws -> String? {
    try db.first("SELECT directory FROM projectDirectories WHERE projectID = ?", [project]) { $0.text(0) }
  }

  /// 本机所有项目的目录绑定。
  public func projectDirectories() throws -> [UUID: String] {
    Dictionary(
      uniqueKeysWithValues: try db.query("SELECT projectID, directory FROM projectDirectories") {
        ($0.uuid(0), $0.text(1))
      })
  }

  /// 全部目录绑定（各台 Mac 的），按项目、Mac 名（`MacAgents.name`）排。
  public func directoryBindings() throws -> [DirectoryBinding] {
    try select(DirectoryBinding.self, orderBy: "projectID, \(DirectoryBinding.macNameSQL), hostID")
  }

  /// 把这台 Mac 本机的目录绑定写成同步的目录绑定记录：有绑定的写（目录末段名变了才改），没了的删；别的 Mac 的不动。
  public func publishDirectoryBindings(host: String) throws {
    try write {
      let local = try projectDirectories()
      let mine = Dictionary(
        uniqueKeysWithValues: try select(DirectoryBinding.self, where: "hostID = ?", [host]).map { ($0.projectID, $0) })
      let now = Date.stamp
      for (project, directory) in local {
        let folder = URL(filePath: directory, directoryHint: .isDirectory).lastPathComponent
        if let existing = mine[project] {
          guard existing.folder != folder else { continue }
          try db.run("UPDATE directoryBindings SET folder = ?, modifiedAt = ? WHERE id = ?", [folder, now, existing.id])
        } else {
          _ = try insert(DirectoryBinding(
            id: DirectoryBinding.recordID(project: project, host: host), projectID: project, hostID: host, folder: folder, createdAt: now, modifiedAt: now))
        }
      }
      for (project, binding) in mine where local[project] == nil {
        try db.run("DELETE FROM directoryBindings WHERE id = ?", [binding.id])
      }
    }
  }

  /// 卡片只能归属存在且未在回收站的项目。必须在写事务内调用，
  /// 与随后的写入之间没有别的写入可以插进来。失效时报错，不静默改去别处。
  func requireLiveProject(_ project: UUID) throws {
    let live = try db.first("SELECT 1 FROM projects WHERE id = ? AND deletedAt IS NULL", [project]) { _ in true }
    guard live != nil else { throw CueStoreError.invalidProject }
  }
}
