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

  public func trashProject(_ id: UUID) throws {
    guard id != Project.defaultID else { throw CueStoreError.defaultProjectUndeletable }
    try write {
      let now = Date.stamp
      try db.run("UPDATE projects SET deletedAt = ?1, modifiedAt = ?1 WHERE id = ?2 AND deletedAt IS NULL", [now, id])
      try endCueSchedules(onTasksIn: "SELECT id FROM cards WHERE projectID = ?2", id, at: now)
    }
  }

  public func restoreProject(_ id: UUID) throws {
    try write {
      try db.run("UPDATE projects SET deletedAt = NULL, modifiedAt = ? WHERE id = ?", [Date.stamp, id])
    }
  }

  public func purgeProject(_ id: UUID) throws {
    try removingFiles { try write {
      let orphaned = try purgeCards(where: "projectID = ? AND deletedAt IS NULL", [id])
      try dropProjects([id])
      return try reclaimAttachments(orphaned)
    } }
  }

  func dropProjects(_ ids: [UUID]) throws {
    let list = Self.idList(ids)
    try db.run("UPDATE cards SET projectID = ?, modifiedAt = ? WHERE projectID IN (SELECT value FROM json_each(?))", [Project.defaultID, Date.stamp, list])
    try db.run("DELETE FROM projectDirectories WHERE projectID IN (SELECT value FROM json_each(?))", [list])
    try db.run("DELETE FROM projects WHERE id IN (SELECT value FROM json_each(?))", [list])
  }

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

  public func projectDirectories() throws -> [UUID: String] {
    Dictionary(
      uniqueKeysWithValues: try db.query("SELECT d.projectID, d.directory FROM projectDirectories d JOIN projects p ON p.id = d.projectID") {
        ($0.uuid(0), $0.text(1))
      })
  }

  public func directoryBindings() throws -> [DirectoryBinding] {
    try select(DirectoryBinding.self, orderBy: "projectID, \(DirectoryBinding.macNameSQL), hostID")
  }

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

  @discardableResult
  func requireLiveProject(_ project: UUID, ifMissing: MissingProject = .reject) throws -> UUID {
    let live = try db.first("SELECT 1 FROM projects WHERE id = ? AND deletedAt IS NULL", [project]) { _ in true }
    if live != nil { return project }
    switch ifMissing {
    case .reject: throw CueStoreError.invalidProject
    case .useDefault: return Project.defaultID
    }
  }
}
