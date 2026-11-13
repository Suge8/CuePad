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

package struct SyncRow: Codable, Equatable, Sendable {
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

  func text(_ column: String) -> String? {
    if case .text(let value)? = fields[column] { value } else { nil }
  }
}

package enum RemoteChange: Sendable {
  case save(SyncRow, systemFields: Data, serverAt: Date? = nil)
  case delete(SyncKey)
}

/// 一次提交（或到点要传的）告诉同步层的：碰过哪些表，其中哪些记录要马上传（nil：别的进程写的，范围不明，读 `pendingUrgent`）。
package struct SyncChange: Sendable {
  package var tables: Set<Table>
  package var urgent: Set<String>?
}

package struct PendingSync: Equatable, Sendable {
  package var saves: [SyncKey]
  package var deletes: [String]
}

package struct RemoteFailure: Sendable {
  package var recordName: String
  package var message: String
}

extension CueStore {
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

  package func pendingSync(among names: Set<String>) throws -> PendingSync {
    let sorted = names.sorted(), ids = JSONColumn.encode(sorted)
    var pending = PendingSync(saves: [], deletes: [])
    for table in Table.synced {
      pending.saves += try pendingSaves(table, where: "t.id IN (SELECT value FROM json_each(?))", [ids])
      pending.deletes += try pendingDeletes(table, among: sorted)
    }
    return pending
  }

  /// `Urgency.changed` 盯的那一列在事务开头的样子（记录 id → 值）。
  func watchedColumns() throws -> [Table: [String: String?]] {
    var values: [Table: [String: String?]] = [:]
    for case (let table, .changed(let column, _)) in Table.urgent {
      values[table] = Dictionary(uniqueKeysWithValues: try db.query("SELECT id, \(column) FROM \(table.rawValue)") { ($0.text(0), $0.textOrNil(1)) })
    }
    return values
  }

  /// 同一个事务里，盯的那一列和开头比变了的记录；没碰过的表不再读。
  func flippedColumns(since before: [Table: [String: String?]]) throws -> Set<String> {
    let touched = db.changesSoFar.tables
    var flipped = Set<String>()
    for (table, old) in before where touched.contains(table.rawValue) {
      for (id, value) in try watchedColumns()[table] ?? [:] where old[id] ?? nil != value { flipped.insert(id) }
    }
    return flipped
  }

  /// 这次增量里要马上传的（`Table.urgent`）；`flipped` 是这次写入改了盯的那一列的记录。
  func urgent(among delta: PendingSync, flipped: Set<String>) throws -> Set<String> {
    let saves = Dictionary(grouping: delta.saves, by: \.table).mapValues { $0.map(\.id) }
    return try urgent(flipped: flipped) { table, condition in
      guard let ids = saves[table] else { return [] }
      return try pendingSaves(table, where: "(\(condition)) AND t.id IN (SELECT value FROM json_each(?))", [JSONColumn.encode(ids)]).map(\.id)
    } deleted: { tables in
      guard !delta.deletes.isEmpty else { return [] }
      return try db.query(
        "SELECT recordName FROM syncRecords WHERE recordName IN (SELECT value FROM json_each(?)) AND recordType IN (SELECT value FROM json_each(?))",
        [JSONColumn.encode(delta.deletes), JSONColumn.encode(tables.map(\.rawValue))]) { $0.text(0) }
    }
  }

  /// 别的进程（命令行里 Cue 的工具、`cuepad`）碰过的这几张表里，此刻要马上传的：那边传不了，由同步层认。
  package func pendingUrgent(in tables: Set<Table>) throws -> Set<String> {
    try urgent(flipped: nil) { table, condition in
      tables.contains(table) ? try pendingSaves(table, where: condition).map(\.id) : []
    } deleted: { urgent in
      try urgent.filter(tables.contains).flatMap { try pendingDeletes($0) }
    }
  }

  /// `saved` 给出这张表里满足条件的待推送；`flipped` 为 nil 是比不了前后（别的进程写的）。
  private func urgent(
    flipped: Set<String>?, saved: (Table, String) throws -> [String], deleted: ([Table]) throws -> [String]
  ) throws -> Set<String> {
    var names = Set<String>()
    var along: [(Table, Table)] = []
    for (table, urgency) in Table.urgent {
      switch urgency {
      case .always: names.formUnion(try saved(table, "1"))
      case .when(let condition): names.formUnion(try saved(table, condition))
      case .changed(_, let companion):
        along.append((table, companion))
        if let flipped { names.formUnion(try saved(table, "1").filter(flipped.contains)) }
      }
    }
    for (table, companion) in along where try !saved(companion, "1").isEmpty {
      names.formUnion(try saved(table, "1"))
    }
    names.formUnion(try deleted(Array(Table.urgent.keys)))
    return names
  }

  /// 待推送的附件记录：文件那一路单独传（CueSync 的 `FileSender`），后台那一路不带它们。附件表小，每次全表查。
  package func pendingAttachments() throws -> [String] {
    try pendingSaves(.attachments, where: "1").map(\.id)
  }

  package func attachments() throws -> [Attachment] { try select(Attachment.self) }

  package func pendingSync() throws -> PendingSync {
    var pending = PendingSync(saves: [], deletes: [])
    for table in Table.synced {
      pending.saves += try pendingSaves(table, where: "1", scanning: true)
      pending.deletes += try pendingDeletes(table)
    }
    return pending
  }

  /// 待推送与推导时的同步变更代数。`since` 是上次确定没有剩下待推送时的代数：其后的提交增量都还记着、范围都明确时，
  /// 只复查它们碰过的记录；否则全量推导（真实库一次约 1 亿条指令，会话在跑时几乎每次上传前都要一遍）。
  package func pendingSync(since generation: Int?) throws -> (pending: PendingSync, generation: Int) {
    guard let generation, let touched = touched(after: generation) else { return (try pendingSync(), syncGeneration) }
    var pending = PendingSync(saves: [], deletes: [])
    let saves = Dictionary(grouping: touched.saves, by: \.table)
    for table in Table.synced {
      guard let keys = saves[table] else { continue }
      let ids = Set(keys.map(\.id)).sorted()
      pending.saves += try pendingSaves(table, where: "t.id IN (SELECT value FROM json_each(?))", [JSONColumn.encode(ids)])
    }
    let deletes = Set(touched.deletes).sorted()
    if !deletes.isEmpty {
      for table in Table.synced { pending.deletes += try pendingDeletes(table, among: deletes) }
    }
    return (pending, syncGeneration)
  }

  private func touched(after generation: Int) -> PendingSync? {
    guard generation < syncGeneration else { return PendingSync(saves: [], deletes: []) }
    let later = syncDeltas.drop { $0.generation <= generation }
    guard later.first?.generation == generation + 1 else { return nil }
    var union = PendingSync(saves: [], deletes: [])
    for (_, delta) in later {
      guard let delta else { return nil }
      union.saves += delta.saves
      union.deletes += delta.deletes
    }
    return union
  }

  func pendingSync(in changes: Changes) throws -> PendingSync {
    var pending = PendingSync(saves: [], deletes: [])
    for table in Table.synced {
      if let rows = changes.rows[table.rawValue] {
        pending.saves += try pendingSaves(table, where: "t.rowid IN (SELECT value FROM json_each(?))", [JSONColumn.encode(rows.sorted())])
      }
      if changes.deletedFrom.contains(table.rawValue) { pending.deletes += try pendingDeletes(table) }
    }
    if let rows = changes.rows[Table.syncRecords.rawValue] {
      let touched = try db.query(
        "SELECT recordName, recordType FROM syncRecords WHERE rowid IN (SELECT value FROM json_each(?)) AND pushedModifiedAt IS NOT NULL",
        [JSONColumn.encode(rows.sorted())]
      ) { ($0.text(0), $0.text(1)) }
      for (type, names) in Dictionary(grouping: touched, by: \.1) {
        guard let table = Table(rawValue: type) else { continue }
        pending.deletes += try pendingDeletes(table, among: names.map(\.0).sorted())
      }
    }
    return pending
  }

  /// `scanning`：翻整张表（全量推导）时走只有 id 与修改时间的覆盖索引（`Schema.pendingIndexes`），不读表本身；按行查的照常走主键。
  private func pendingSaves(
    _ table: Table, where condition: String, _ arguments: [any SQLBindable] = [], scanning: Bool = false
  ) throws -> [SyncKey] {
    try db.query(
      """
      SELECT t.id FROM \(table.rawValue) t \(scanning ? "INDEXED BY \(table.rawValue)_modified" : "")
      LEFT JOIN syncRecords s INDEXED BY syncRecords_pushed ON s.recordName = t.id
      WHERE (\(condition)) AND (s.pushedModifiedAt IS NULL OR t.modifiedAt > s.pushedModifiedAt) ORDER BY t.rowid
      """, arguments
    ) { SyncKey(table: table, id: $0.text(0)) }
  }

  private func pendingDeletes(_ table: Table, among names: [String]? = nil) throws -> [String] {
    try db.query(
      """
      SELECT s.recordName FROM \(names == nil ? "syncRecords s" : "json_each(?) j CROSS JOIN syncRecords s ON s.recordName = j.value")
      WHERE s.recordType = ? AND s.pushedModifiedAt IS NOT NULL AND NOT EXISTS (SELECT 1 FROM \(table.rawValue) t WHERE t.id = s.recordName)
      """,
      (names.map { [JSONColumn.encode($0)] } ?? []) + [table.rawValue]
    ) { $0.text(0) }
  }

  package func modifiedAts(in table: Table) throws -> [String: Int64] {
    Dictionary(uniqueKeysWithValues: try db.query("SELECT id, modifiedAt FROM \(table.rawValue)") { ($0.text(0), $0.int(1)) })
  }

  package func systemFields(of recordName: String) throws -> Data? {
    guard let packed = try db.first("SELECT systemFields FROM syncRecords WHERE recordName = ?", [recordName], { $0.blobOrNil(0) }) ?? nil else { return nil }
    return SystemFields.unpack(packed)
  }

  package func syncedRecords() throws -> [String: (table: Table, pushed: Int64)] {
    var synced: [String: (table: Table, pushed: Int64)] = [:]
    let rows = try db.query("SELECT recordName, recordType, pushedModifiedAt FROM syncRecords WHERE pushedModifiedAt IS NOT NULL") {
      ($0.text(0), $0.text(1), $0.int(2))
    }
    for (name, type, pushed) in rows {
      if let table = Table(rawValue: type) { synced[name] = (table, pushed) }
    }
    return synced
  }

  /// 临交出前核对：这一版已被服务器收下的作废（挑批之后、交出之前，马上传那一路已把它传完了），不再交一次；
  /// 投送请求另在同一事务里核对版本并保留发送权，与撤回互斥。其余记录沿用挑批时的记账。
  package func reserveForUpload(_ versions: [(name: String, table: Table, modifiedAt: Int64)]) throws -> Set<String> {
    let pushed = Dictionary(
      uniqueKeysWithValues: try db.query(
        "SELECT recordName, pushedModifiedAt FROM syncRecords WHERE recordName IN (SELECT value FROM json_each(?)) AND pushedModifiedAt IS NOT NULL",
        [JSONColumn.encode(versions.map(\.name))]) { ($0.text(0), $0.int(1)) })
    let accepted = Set(versions.filter { version in pushed[version.name].map { version.modifiedAt <= $0 } == true }.map(\.name))
    let deliveries = versions.filter { $0.table == .deliveryRequests && !accepted.contains($0.name) }
    guard !deliveries.isEmpty else { return accepted }
    return try write {
      var obsolete = accepted
      for version in deliveries {
        guard try db.first("SELECT 1 FROM deliveryRequests WHERE id = ? AND modifiedAt = ?", [version.name, version.modifiedAt], { _ in true }) != nil else {
          obsolete.insert(version.name)
          continue
        }
        try noteSentVersions([version])
      }
      return obsolete
    }
  }

  /// 本机把这几条记录的这一版交给服务器（构造上传批次时）。结果没回到本机就崩溃、或回包在路上丢了，服务器其实收下了它；
  /// 之后它经拉取或重传被拒附的服务器版本回来，按修改时间认出是自己的（`applyVersion`），不当成并发编辑留冲突副本。
  /// 同一时刻只有一批在路上，所以每条记录记一个时间就够：已有一版交出去而服务器还没收下时保留那一版（它最可能先回来），
  /// 收下之后再交出去的才覆盖。
  package func noteSent(_ versions: [(name: String, table: Table, modifiedAt: Int64)]) throws {
    try write { try noteSentVersions(versions) }
  }

  private func noteSentVersions(_ versions: [(name: String, table: Table, modifiedAt: Int64)]) throws {
    for version in versions {
      try db.run(
        """
        INSERT INTO syncRecords (recordName, recordType, sentModifiedAt) VALUES (?, ?, ?)
        ON CONFLICT(recordName) DO UPDATE SET sentModifiedAt = excluded.sentModifiedAt
        WHERE syncRecords.sentModifiedAt IS NULL OR syncRecords.sentModifiedAt <= COALESCE(syncRecords.pushedModifiedAt, -1)
        """, [version.name, version.table.rawValue, version.modifiedAt])
    }
  }

  /// 你发出的话的那条消息（带请求标识，`ChatMessage.deliveryID`）上了服务器，同一事务核对关联资格后收走投送请求（`removeUploadedDeliveries`）；窗口内原卡未到时保留。
  /// 不在写对话时收：请求的删除随回执马上传，消息走后台那一路、要等合并窗口与前面的批次，别的设备会先收到删除、气泡就空着。
  /// 服务器上删除排在消息之后，拉到删除时消息已经在了。
  /// `serverAt` 是服务器收下它的时刻（上传回执里那条记录的 creationDate）：投送请求记进本机列 `DeliveryRequest.serverAt`，同拉到时（`RemoteChange.save`）。
  package func markPushed(_ pushed: [(row: SyncRow, systemFields: Data, serverAt: Date?)]) throws {
    guard !pushed.isEmpty else { return }
    let messages = JSONColumn.encode(pushed.filter { $0.row.table == .piMessages }.map(\.row.id))
    try write {
      for (row, systemFields, serverAt) in pushed {
        try setMetadata(row.table, row.id, systemFields, pushed: row.modifiedAt)
        if row.table == .deliveryRequests, let serverAt {
          try db.run("UPDATE deliveryRequests SET serverAt = ? WHERE id = ? AND serverAt IS NULL", [serverAt, row.id])
        }
        // 通知标志随这次上传送出，之后不能再被本机别的改动带上去（见 `StateRecorder`）；不动修改时间，不会让记录重新待推送
        if Table.notifyFlagged.contains(row.table), let sent = row.fields["notify"], sent != .null {
          try db.run("UPDATE \(row.table.rawValue) SET notify = NULL WHERE id = ? AND notify = ?", [row.id, sent])
        }
      }
      let deliveries = try db.query(
        "SELECT deliveryID FROM piMessages WHERE id IN (SELECT value FROM json_each(?)) AND deliveryID IS NOT NULL", [messages]) { $0.uuid(0) }
      try removeUploadedDeliveries(among: Set(deliveries))
    }
  }

  package func dropSyncMetadata(_ recordNames: [String]) throws {
    guard !recordNames.isEmpty else { return }
    try write {
      for name in recordNames { try db.run("DELETE FROM syncRecords WHERE recordName = ?", [name]) }
    }
  }

  package func syncState(_ key: String) throws -> Data? {
    try db.first("SELECT value FROM syncState WHERE key = ?", [key]) { $0.blobOrNil(0) } ?? nil
  }

  package func setSyncState(_ key: String, _ value: Data?) throws {
    try write {
      if let value {
        try db.run("INSERT INTO syncState (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value])
      } else {
        try db.run("DELETE FROM syncState WHERE key = ?", [key])
      }
    }
  }

  package func resetSyncMetadata() throws {
    try write {
      try db.run("DELETE FROM syncRecords")
      try db.run("DELETE FROM syncState WHERE key NOT LIKE 'capture:%'")  // 分享入库的标记不属于同步状态：条目还在时要留着
    }
  }

  /// 文件在同一个写事务里删（同 `reclaimFiles`）：别的连接不能在清库之后、删文件之前提交引用，不然它刚留的保底跟着被删，记录却在。
  package func eraseSyncedData() throws {
    try write {
      for table in Table.synced { try db.run("DELETE FROM \(table.rawValue)") }
      try db.run("DELETE FROM projectDirectories")
      try db.run("DELETE FROM syncRecords")
      try db.run("DELETE FROM syncState")
      try files.removeAll()
    }
  }
}
