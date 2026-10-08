import Foundation

// CueSync 使用的窄接口（`package` 可见，不进入应用的公开 API）。同步表的行以"字段字典"交换，
// CueSync 负责它与 CKRecord 的映射；冲突判定、事务与本机元数据留在 Store 里，保证一次远端应用是一个写事务。

package struct SyncKey: Hashable, Sendable {
  package var table: Table
  package var id: String
  package init(table: Table, id: String) {
    self.table = table
    self.id = id
  }
}

/// 一条同步表记录：`fields` 含 `id` 与该表全部列（NULL 为 `.null`）。
package struct SyncRow: Equatable, Sendable {
  package var table: Table
  package var fields: [String: SQLValue]

  package init(table: Table, fields: [String: SQLValue]) {
    self.table = table
    self.fields = fields
  }

  package var id: String {
    if case .text(let value)? = fields["id"] { value } else { "" }
  }

  package var modifiedAt: Int64 {
    if case .int(let value)? = fields["modifiedAt"] { value } else { 0 }
  }

  fileprivate func text(_ column: String) -> String? {
    if case .text(let value)? = fields[column] { value } else { nil }
  }
}

package enum RemoteChange: Sendable {
  case save(SyncRow, systemFields: Data)
  case delete(SyncKey)
}

/// 需要推送的变更：由数据库推导。
package struct PendingSync: Equatable, Sendable {
  /// 从未推送过、或推送后又改过的记录。
  package var saves: [SyncKey]
  /// 服务器上有（存在元数据）但本机已不存在的记录名。
  package var deletes: [String]
}

package struct RemoteFailure: Sendable {
  package var recordName: String
  package var message: String
}

extension CueStore {
  /// 表里各列声明的 SQLite 类型（TEXT / INTEGER）；CloudKit schema 的字段类型由它推出。
  package func columnTypes(of table: Table) throws -> [String: String] {
    Dictionary(
      uniqueKeysWithValues: try db.query("SELECT name, type FROM pragma_table_info('\(table.rawValue)')") { ($0.text(0), $0.text(1)) })
  }

  package func syncRow(recordName: String) throws -> SyncRow? {
    for table in Table.synced {
      if let row = try readSyncRow(table, recordName) { return row }
    }
    return nil
  }

  /// 这条记录此刻是不是待推送（从未推送过，或推送后又改过）；本机没有这条记录时不是。
  package func isPending(_ recordName: String) throws -> Bool {
    for table in Table.synced where try !pendingSaves(table, where: "t.id = ?", [recordName]).isEmpty { return true }
    return false
  }

  /// 全量对账：所有同步表里待推送的记录。
  package func pendingSync() throws -> PendingSync {
    var pending = PendingSync(saves: [], deletes: [])
    for table in Table.synced {
      pending.saves += try pendingSaves(table, where: "1")
      pending.deletes += try pendingDeletes(table)
    }
    return pending
  }

  /// 一次提交里改动的行中变成待推送的；删除只查删过行的表。
  func pendingSync(in changes: Changes) throws -> PendingSync {
    var pending = PendingSync(saves: [], deletes: [])
    for table in Table.synced {
      if let rows = changes.rows[table.rawValue] {
        pending.saves += try pendingSaves(table, where: "t.rowid IN (\(rows.sorted().map(String.init).joined(separator: ",")))")
      }
      if changes.deletedFrom.contains(table.rawValue) { pending.deletes += try pendingDeletes(table) }
    }
    return pending
  }

  /// "待推送"的唯一定义（全量、增量与单条判定都从这里来）：从未推送过，或推送后又改过。
  private func pendingSaves(_ table: Table, where condition: String, _ arguments: [any SQLBindable] = []) throws -> [SyncKey] {
    try db.query(
      """
      SELECT t.id FROM \(table.rawValue) t LEFT JOIN syncRecords s ON s.recordName = t.id
      WHERE (\(condition)) AND (s.recordName IS NULL OR t.modifiedAt > s.pushedModifiedAt) ORDER BY t.rowid
      """, arguments
    ) { SyncKey(table: table, id: $0.text(0)) }
  }

  private func pendingDeletes(_ table: Table) throws -> [String] {
    try db.query(
      "SELECT recordName FROM syncRecords WHERE recordType = ? AND recordName NOT IN (SELECT id FROM \(table.rawValue))",
      [table.rawValue]
    ) { $0.text(0) }
  }

  /// 一张同步表里本机每条记录的修改时间（记录 id → `modifiedAt` 毫秒）：与服务器上的版本比较，看哪些本机还没有或较旧。
  package func modifiedAts(in table: Table) throws -> [String: Int64] {
    Dictionary(uniqueKeysWithValues: try db.query("SELECT id, modifiedAt FROM \(table.rawValue)") { ($0.text(0), $0.int(1)) })
  }

  package func systemFields(of recordName: String) throws -> Data? {
    try db.first("SELECT systemFields FROM syncRecords WHERE recordName = ?", [recordName]) { $0.blobOrNil(0) } ?? nil
  }

  /// 服务器已接受这条记录：记下它的系统字段与被推送版本的修改时间。之后再改才会重新变成待推送。
  /// 返回本机版本是否在这之后又改过（仍待推送）。
  package func markPushed(_ row: SyncRow, systemFields: Data) throws -> Bool {
    try write {
      try setMetadata(row.table, row.id, systemFields, pushed: row.modifiedAt)
      // 通知标志随这次上传送出，之后不能再被本机别的改动带上去（见 `PiStateRecorder`）；不动修改时间，不会让记录重新待推送
      if row.table == .piSessionStates, let sent = row.fields["notify"], sent != .null {
        try db.run("UPDATE piSessionStates SET notify = NULL WHERE id = ? AND notify = ?", [row.id, sent])
      }
      return try readSyncRow(row.table, row.id).map { $0.modifiedAt > row.modifiedAt } ?? false
    }
  }

  /// 服务器上已没有这条记录（删除已确认、或本来就不存在）：忘掉它的元数据。
  /// 数据表里还有该记录时，它因此重新变成待上传。
  package func dropSyncMetadata(_ recordName: String) throws {
    try write { try db.run("DELETE FROM syncRecords WHERE recordName = ?", [recordName]) }
  }

  package func engineState() throws -> Data? {
    try db.first("SELECT value FROM syncState WHERE key = 'engine'") { $0.blobOrNil(0) } ?? nil
  }

  package func setEngineState(_ state: Data) throws {
    try write {
      try db.run(
        "INSERT INTO syncState (key, value) VALUES ('engine', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        [state])
    }
  }

  /// 忘掉所有服务器元数据与引擎状态：本机的每条同步记录重新变成待上传（新账号、云端数据被清除后重传）。
  package func resetSyncMetadata() throws {
    try write {
      try db.run("DELETE FROM syncRecords")
      try db.run("DELETE FROM syncState")
    }
  }

  /// 丢弃本机的全部同步数据（含附件文件与项目目录绑定）；Pi 会话索引等本机表不动。
  package func eraseSyncedData() throws {
    try write {
      for table in Table.synced { try db.run("DELETE FROM \(table.rawValue)") }
      try db.run("DELETE FROM projectDirectories")
      try db.run("DELETE FROM syncRecords")
      try db.run("DELETE FROM syncState")
    }
    try files.removeAll()
  }

  /// 在一个写事务里应用一批远端变更；提交后一次通知订阅者。单条记录失败（如字段非法）只回滚该条并报告，不影响其余。
  package func applyRemote(_ changes: [RemoteChange]) throws -> [RemoteFailure] {
    var failures: [RemoteFailure] = []
    var removedHashes: [String] = []
    try write {
      for change in changes {
        try db.exec("SAVEPOINT remote")
        do {
          if let hash = try apply(change) { removedHashes.append(hash) }
          try db.exec("RELEASE remote")
        } catch {
          try db.exec("ROLLBACK TO remote")
          try db.exec("RELEASE remote")
          failures.append(RemoteFailure(recordName: change.recordName, message: "\(error)"))
        }
      }
      if changes.contains(where: \.touchesCards) { try repairCardTree() }
    }
    return failures + (try removeFiles(of: removedHashes))
  }
}

extension RemoteChange {
  fileprivate var touchesCards: Bool {
    switch self {
    case .save(let row, _): row.table == .cards
    case .delete(let key): key.table == .cards
    }
  }

  fileprivate var recordName: String {
    switch self {
    case .save(let row, _): row.id
    case .delete(let key): key.id
    }
  }
}

// MARK: 应用远端变更

extension CueStore {
  private func readSyncRow(_ table: Table, _ id: String) throws -> SyncRow? {
    let columns = table.columns
    return try db.first(
      "SELECT \(columns.joined(separator: ", ")) FROM \(table.rawValue) WHERE id = ?", [id]
    ) { row in
      SyncRow(table: table, fields: Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($1, row.value(Int32($0))) }))
    }
  }

  private func setMetadata(_ table: Table, _ id: String, _ systemFields: Data, pushed: Int64) throws {
    try db.run(
      """
      INSERT INTO syncRecords (recordName, recordType, systemFields, pushedModifiedAt) VALUES (?, ?, ?, ?)
      ON CONFLICT(recordName) DO UPDATE SET systemFields = excluded.systemFields, pushedModifiedAt = excluded.pushedModifiedAt
      """, [id, table.rawValue, systemFields, pushed])
  }

  private func overwrite(_ row: SyncRow) throws {
    let columns = row.table.columns
    let placeholders = columns.map { _ in "?" }.joined(separator: ", ")
    let assignments = columns.dropFirst().map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
    try db.run(
      """
      INSERT INTO \(row.table.rawValue) (\(columns.joined(separator: ", "))) VALUES (\(placeholders))
      ON CONFLICT(id) DO UPDATE SET \(assignments)
      """, columns.map { row.fields[$0] ?? .null })
  }

  /// 返回被删附件的哈希（提交后回收文件）。
  private func apply(_ change: RemoteChange) throws -> String? {
    switch change {
    case .delete(let key):
      var hash: String?
      if key.table == .attachments {
        hash = try db.first("SELECT hash FROM attachments WHERE id = ?", [key.id]) { $0.text(0) }
      }
      try db.run("DELETE FROM \(key.table.rawValue) WHERE id = ?", [key.id])
      try db.run("DELETE FROM syncRecords WHERE recordName = ?", [key.id])
      if key.table == .projects {
        // 项目已在别处永久删除，不会再"稍后到达"：本机遗留在它名下的卡片（多半是离线期间新写的），
        // 与本地 purgeProject 一致地释放到未分类，内容保留，不悬空隐藏。
        let now = Date.stamp
        try db.run("UPDATE cards SET projectID = NULL, modifiedAt = ? WHERE projectID = ?", [now, key.id])
        try db.run("DELETE FROM projectDirectories WHERE projectID = ?", [key.id])
      }
      return hash
    case .save(let remote, let systemFields):
      try applySave(remote, systemFields)
      return nil
    }
  }

  /// 冲突规则：
  /// - 本机没有该记录：若有元数据（本机已删除、删除待推送）则忽略远端；否则插入。
  /// - 本机自上次推送后没改过：直接采用远端。
  /// - 本机有未推送的改动：`modifiedAt` 较新的整条记录留下，同刻以服务器为准（服务器是唯一裁决者，各设备因此收敛）；
  ///   卡片正文不同时，被淘汰的正文另存为冲突副本，不静默覆盖。
  /// 排序键相同不在这里处理：读取时按 id 打平，移动时重排。
  private func applySave(_ remote: SyncRow, _ systemFields: Data) throws {
    let awaitingResult = try remote.table == .deliveryRequests && isAwaitingResult(remote.id)
    try applyVersion(remote, systemFields)
    if awaitingResult {
      try db.run(
        "UPDATE deliveryRequests SET resultReceivedAt = ? WHERE id = ? AND status IN ('succeeded', 'failed')",
        [Date.stamp, remote.id])
    }
  }

  private func applyVersion(_ remote: SyncRow, _ systemFields: Data) throws {
    var remote = remote
    // 通知标志只由写会话状态的那台 Mac 置位、上传即清：远端带回来的（含自己上传的回声）不能再让本机的下一次改动带上它
    if remote.table == .piSessionStates { remote.fields["notify"] = .null }
    let table = remote.table
    let pushed = try db.first("SELECT pushedModifiedAt FROM syncRecords WHERE recordName = ?", [remote.id]) { $0.int(0) }
    guard let local = try readSyncRow(table, remote.id) else {
      if pushed != nil { return }
      try overwrite(remote)
      try setMetadata(table, remote.id, systemFields, pushed: remote.modifiedAt)
      return
    }

    let unpushed = pushed.map { local.modifiedAt > $0 } ?? true
    guard unpushed else {
      try overwrite(remote)
      try setMetadata(table, remote.id, systemFields, pushed: remote.modifiedAt)
      return
    }

    let remoteWins = remote.modifiedAt >= local.modifiedAt
    if table == .cards, let localBody = local.text("body"), let remoteBody = remote.text("body"), localBody != remoteBody {
      try insertConflictCopy(of: remoteWins ? local : remote, keeping: remoteWins ? remote : local)
    }
    if remoteWins {
      try overwrite(remote)
      try setMetadata(table, remote.id, systemFields, pushed: remote.modifiedAt)
    } else {
      // 本机版本留下并继续待推送，但要带上服务器最新的系统字段，否则推送会再次冲突。
      try setMetadata(table, remote.id, systemFields, pushed: pushed ?? 0)
    }
  }

  /// 投送请求在本机还在等结果：远端版本把它变成完成时，记下本机时刻（往返时间的终点）。
  /// 执行方在本机写结果，不走远端应用；第一次就收到已完成请求的设备从没等过它，也不记。
  private func isAwaitingResult(_ id: String) throws -> Bool {
    try db.first(
      "SELECT 1 FROM deliveryRequests WHERE id = ? AND status IN ('pending', 'executing')", [id]) { _ in true } != nil
  }

  /// 卡片层级在远端变更之后仍要成立（见 `CardLinks.repairs`）；改写的卡片会再推送，让各设备收敛。
  /// 修改时间至少比现有的晚一毫秒：刚收下的远端版本可能带着比本机时钟更晚的时间，改写要算作更新的版本。
  private func repairCardTree() throws {
    let now = Date.stamp
    for (id, link) in try CardLinks(db).repairs() {
      try db.run(
        "UPDATE cards SET parentID = ?, projectID = ?, modifiedAt = MAX(modifiedAt + 1, ?) WHERE id = ?", [link.parent, link.project, now, id])
    }
  }

  /// 被淘汰的卡片版本存成一张新卡（和留下的版本同项目、放在项目最前），指回原卡。副本是灵感（不带状态、上级与会话），
  /// 不会在看板上多出一条任务。
  private func insertConflictCopy(of loser: SyncRow, keeping winner: SyncRow) throws {
    let projectID = winner.text("projectID").flatMap(UUID.init(uuidString:))
    let first = try db.first("SELECT MIN(sortKey) FROM cards WHERE projectID IS ?", [projectID]) { $0.textOrNil(0) } ?? nil
    let now = Date.stamp
    var fields = loser.fields
    fields["id"] = .text(UUID().uuidString.lowercased())
    fields["projectID"] = winner.fields["projectID"] ?? .null
    fields["conflictOf"] = .text(winner.id)
    fields["sortKey"] = .text(SortKey.before(first))
    fields["deletedAt"] = .null
    fields["isPinned"] = .int(0)
    for column in ["parentID", "todoAt", "startedAt", "completedAt", "piSessionID"] { fields[column] = .null }
    fields["createdAt"] = now.sqlValue
    fields["modifiedAt"] = now.sqlValue
    try overwrite(SyncRow(table: .cards, fields: fields))
  }

  /// 远端删除附件记录后回收文件；仍被卡片或发送记录引用的保留（引用它的记录也许马上就到）。删不掉的作为失败报告。
  private func removeFiles(of hashes: [String]) throws -> [RemoteFailure] {
    var failures: [RemoteFailure] = []
    for hash in Set(hashes).sorted() where try !isImageReferenced(hash) {
      do { try files.remove(hash: hash) } catch {
        failures.append(RemoteFailure(recordName: hash, message: "附件文件没能删除：\(error)"))
      }
    }
    return failures
  }
}
