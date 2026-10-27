import CueText
import Foundation

extension CueStore {
  /// 在一个写事务里应用一批远端变更；提交后一次通知订阅者。单条记录失败（如字段非法）只回滚该条并报告，不影响其余。
  package func applyRemote(_ changes: [RemoteChange]) throws -> [RemoteFailure] {
    var failures: [RemoteFailure] = []
    var removedKeys: [String] = []
    try write {
      for change in changes {
        try db.exec("SAVEPOINT remote")
        do {
          if let key = try apply(change) { removedKeys.append(key) }
          try db.exec("RELEASE remote")
        } catch {
          try db.exec("ROLLBACK TO remote")
          try db.exec("RELEASE remote")
          failures.append(RemoteFailure(recordName: change.recordName, message: "\(error)"))
        }
      }
      let cards = Set(changes.compactMap(\.cardID))
      if !cards.isEmpty { try repairCardTree(touching: cards) }
      if changes.contains(where: \.touchesLaunches) { try claimLaunchedCards() }
    }
    return failures + (try removeFiles(of: removedKeys))
  }

  func readSyncRow(_ table: Table, _ id: String) throws -> SyncRow? {
    let columns = table.columns
    return try db.first(
      "SELECT \(columns.joined(separator: ", ")) FROM \(table.rawValue) WHERE id = ?", [id]
    ) { row in
      SyncRow(table: table, fields: Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($1, row.value(Int32($0))) }))
    }
  }

  func setMetadata(_ table: Table, _ id: String, _ systemFields: Data, pushed: Int64) throws {
    try db.run(
      """
      INSERT INTO syncRecords (recordName, recordType, systemFields, pushedModifiedAt) VALUES (?, ?, ?, ?)
      ON CONFLICT(recordName) DO UPDATE SET systemFields = excluded.systemFields, pushedModifiedAt = excluded.pushedModifiedAt
      """, [id, table.rawValue, SystemFields.pack(systemFields), pushed])
  }

  private func overwrite(_ row: SyncRow) throws {
    let columns = row.table.columns
    try copyingRemote { try db.run(Self.upsertSQL(row.table, columns), columns.map { row.fields[$0] ?? .null }) }
  }

  /// 返回被删附件的键（提交后回收文件）。
  private func apply(_ change: RemoteChange) throws -> String? {
    switch change {
    case .delete(let key):
      var attachment: String?
      if key.table == .attachments {
        attachment = try db.first("SELECT hash, format FROM attachments WHERE id = ?", [key.id]) { AttachmentKey.make(hash: $0.text(0), format: $0.text(1)) }
      }
      try db.run("DELETE FROM \(key.table.rawValue) WHERE id = ?", [key.id])
      try db.run("DELETE FROM syncRecords WHERE recordName = ?", [key.id])
      if key.table == .projects {
        // 项目已在别处永久删除，不会再"稍后到达"：本机遗留在它名下的卡片（多半是离线期间新写的），
        // 与本地 purgeProject 一致地释放到默认项目，内容保留，不悬空隐藏。
        let now = Date.stamp
        try db.run("UPDATE cards SET projectID = ?, modifiedAt = ? WHERE projectID = ?", [Project.defaultID, now, key.id])
        try db.run("DELETE FROM projectDirectories WHERE projectID = ?", [key.id])
      }
      return attachment
    case .save(let remote, let systemFields, let serverAt):
      try applySave(remote, systemFields, serverAt: serverAt)
      return nil
    }
  }

  /// 冲突规则：
  /// - 本机没有该记录：若有元数据（本机已删除、删除待推送）则忽略远端；否则插入。
  /// - 本机自上次推送后没改过：直接采用远端。
  /// - 本机有未推送的改动：`modifiedAt` 较新的整条记录留下，同刻以服务器为准（服务器是唯一裁决者，各设备因此收敛）；
  ///   卡片正文不同时，被淘汰的正文另存为冲突副本，不静默覆盖。
  /// 本机自己上传的版本回来（回声）不是并发编辑：由交出去与服务器收下的修改时间认出（`applyVersion`）。
  /// 排序键相同不在这里处理：读取时按 id 打平，移动时重排。
  private func applySave(_ remote: SyncRow, _ systemFields: Data, serverAt: Date?) throws {
    let awaitingResult = try remote.table == .deliveryRequests && isAwaitingResult(remote.id)
    try applyVersion(remote, systemFields)
    if remote.table == .deliveryRequests, let serverAt {
      try db.run("UPDATE deliveryRequests SET serverAt = ? WHERE id = ? AND serverAt IS NULL", [serverAt, remote.id])
    }
    if awaitingResult {
      try db.run(
        "UPDATE deliveryRequests SET resultReceivedAt = ? WHERE id = ? AND status IN ('succeeded', 'failed')",
        [Date.stamp, remote.id])
    }
  }

  private func applyVersion(_ remote: SyncRow, _ systemFields: Data) throws {
    var remote = remote
    // 通知标志只由置位的那台 Mac 上传、上传即清：远端带回来的（含自己上传的回声）不能再让本机的下一次改动带上它
    if Table.notifyFlagged.contains(remote.table) { remote.fields["notify"] = .null }
    // 默认项目之前的版本写的未分类卡片不带项目：就是默认项目里的（同 `Schema` 升级的那一步）；不补上，读卡片层级时当场崩溃
    if remote.table == .cards, (remote.fields["projectID"] ?? .null) == .null { remote.fields["projectID"] = .text(Project.defaultID.uuidString.lowercased()) }
    let table = remote.table
    let (pushed, sent) = try db.first("SELECT pushedModifiedAt, sentModifiedAt FROM syncRecords WHERE recordName = ?", [remote.id]) {
      ($0.intOrNil(0), $0.intOrNil(1))
    } ?? (nil, nil)
    // 交出去而结果没回到本机的那一版回来了（崩溃、回包丢失）：服务器收下了它，记账；本机的行不动
    if remote.modifiedAt == sent {
      if remote.modifiedAt > (pushed ?? .min) { try setMetadata(table, remote.id, systemFields, pushed: remote.modifiedAt) }
      return
    }
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

    // 远端不比本机已记下的推送版本新：是本机自己上传过的版本（回声）或更旧的，本机已有更新的编辑，没有什么要合并的。
    // 别的设备并发编辑的版本晚于本机上次同步的版本，不会落在这里。
    if let pushed, remote.modifiedAt <= pushed { return }

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
      "SELECT 1 FROM deliveryRequests WHERE id = ? AND status IN (\(DeliveryStatus.openSQL))", [id]) { _ in true } != nil
  }

  /// 卡片层级在远端变更之后仍要成立（见 `CardLinks.repairs`）；改写的卡片会再推送，让各设备收敛。
  private func repairCardTree(touching changed: Set<UUID>) throws {
    try apply(try CardLinks(db).repairs(touching: changed))
  }

  /// 被淘汰的卡片版本存成一张新卡（和留下的版本同项目、放在项目最前），指回原卡。副本是灵感（不带状态、上级与会话），
  /// 不会在看板上多出一条任务。
  private func insertConflictCopy(of loser: SyncRow, keeping winner: SyncRow) throws {
    let first = try db.first("SELECT MIN(sortKey) FROM cards WHERE projectID = ?", [winner.fields["projectID"] ?? .null]) { $0.textOrNil(0) } ?? nil
    let now = Date.stamp
    var fields = loser.fields
    fields["id"] = .text(UUID().uuidString.lowercased())
    fields["projectID"] = winner.fields["projectID"] ?? .null
    fields["conflictOf"] = .text(winner.id)
    fields["sortKey"] = .text(SortKey.before(first))
    fields["deletedAt"] = .null
    fields["isPinned"] = .int(0)
    for column in ["parentID", "todoAt", "startedAt", "completedAt", "piSessionID", "formerSessionIDs"] { fields[column] = .null }
    fields["createdAt"] = now.sqlValue
    fields["modifiedAt"] = now.sqlValue
    try overwrite(SyncRow(table: .cards, fields: fields))
  }

  /// 远端删除附件记录后回收文件；仍被引用的保留（`isAttachmentReferenced`）（引用它的记录也许马上就到）。删不掉的作为失败报告。
  private func removeFiles(of keys: [String]) throws -> [RemoteFailure] {
    var failures: [RemoteFailure] = []
    for key in Set(keys).sorted() where try !isAttachmentReferenced(key) {
      do { try files.remove(key) } catch {
        failures.append(RemoteFailure(recordName: key, message: String(localized: "附件文件没能删除：\(String(describing: error))")))
      }
    }
    return failures
  }
}

extension RemoteChange {
  /// 可能让一次"开新会话"被认领：会话记录、投送请求或卡片到了（同步乱序，哪个先到都要认）。
  fileprivate var touchesLaunches: Bool {
    switch self {
    case .save(let row, _, _): [.piSessionStates, .deliveryRequests, .cards].contains(row.table)
    case .delete: false
    }
  }

  /// 这条变更涉及的卡片 id；不是卡片的变更为 nil。
  fileprivate var cardID: UUID? {
    switch self {
    case .save(let row, _, _): row.table == .cards ? UUID(uuidString: row.id) : nil
    case .delete(let key): key.table == .cards ? UUID(uuidString: key.id) : nil
    }
  }

  fileprivate var recordName: String {
    switch self {
    case .save(let row, _, _): row.id
    case .delete(let key): key.id
    }
  }
}
