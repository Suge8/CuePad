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
  /// `serverAt`：服务器收下这条记录的时刻（投送请求记进本机列 `DeliveryRequest.serverAt`）。
  case save(SyncRow, systemFields: Data, serverAt: Date? = nil)
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

  /// 这几条里此刻待推送的（马上传只看自己要的几条，按主键查，不全量推导）。
  package func pendingSync(among names: Set<String>) throws -> PendingSync {
    let sorted = names.sorted(), ids = JSONColumn.encode(sorted)
    var pending = PendingSync(saves: [], deletes: [])
    for table in Table.synced {
      pending.saves += try pendingSaves(table, where: "t.id IN (SELECT value FROM json_each(?))", [ids])
      pending.deletes += try pendingDeletes(table, among: sorted)
    }
    return pending
  }

  /// Cue 对你说的话里待推送的，连同 Cue 此刻的样子（一轮的话与歇着同一个事务写下，要一起到）：发送者马上传它们，不攒批。
  /// Cue 的话多半是命令行进程（Cue 的工具）写的，那边传不了；所以由同步层认，不靠写的人叫上传。
  package func pendingSpeech() throws -> Set<String> {
    let said = try pendingSaves(.cueMessages, where: "t.author = 'cue'").map(\.id)
    guard !said.isEmpty else { return [] }
    return Set(said + (try pendingSaves(.cueState, where: "1").map(\.id)))
  }

  /// 待推送的附件记录：文件那一路单独传（CueSync 的 `FileSender`），后台那一路不带它们。附件表小，每次全表查。
  package func pendingAttachments() throws -> [String] {
    try pendingSaves(.attachments, where: "1").map(\.id)
  }

  /// 全部附件记录：文件那一路据此找本机还没有的文件（CueSync 的 `FileFetcher`）。
  package func attachments() throws -> [Attachment] { try select(Attachment.self) }

  /// 全量对账：所有同步表里待推送的记录。
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

  /// `generation` 之后各次提交的增量合起来；有范围不明的、或早的已不在记着的里面时为 nil。
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

  /// 一次提交里改动的行中变成待推送的；删除只查删过行的表。
  func pendingSync(in changes: Changes) throws -> PendingSync {
    var pending = PendingSync(saves: [], deletes: [])
    for table in Table.synced {
      if let rows = changes.rows[table.rawValue] {
        pending.saves += try pendingSaves(table, where: "t.rowid IN (SELECT value FROM json_each(?))", [JSONColumn.encode(rows.sorted())])
      }
      if changes.deletedFrom.contains(table.rawValue) { pending.deletes += try pendingDeletes(table) }
    }
    return pending
  }

  /// "待推送"的唯一定义（全量、增量与单条判定都从这里来）：服务器从没收下过，或收下后又改过。
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

  /// "待推送的删除"的唯一定义：服务器收下过，本机的行已不在。`among` 只看这几条（按增量复查时，从这几条查起）。
  private func pendingDeletes(_ table: Table, among names: [String]? = nil) throws -> [String] {
    try db.query(
      """
      SELECT s.recordName FROM \(names == nil ? "syncRecords s" : "json_each(?) j CROSS JOIN syncRecords s ON s.recordName = j.value")
      WHERE s.recordType = ? AND s.pushedModifiedAt IS NOT NULL AND NOT EXISTS (SELECT 1 FROM \(table.rawValue) t WHERE t.id = s.recordName)
      """,
      (names.map { [JSONColumn.encode($0)] } ?? []) + [table.rawValue]
    ) { $0.text(0) }
  }

  /// 一张同步表里本机每条记录的修改时间（记录 id → `modifiedAt` 毫秒）：与服务器上的版本比较，看哪些本机还没有或较旧。
  package func modifiedAts(in table: Table) throws -> [String: Int64] {
    Dictionary(uniqueKeysWithValues: try db.query("SELECT id, modifiedAt FROM \(table.rawValue)") { ($0.text(0), $0.int(1)) })
  }

  /// 上次服务器记录的系统字段归档（存法见 `SystemFields`）。
  package func systemFields(of recordName: String) throws -> Data? {
    guard let packed = try db.first("SELECT systemFields FROM syncRecords WHERE recordName = ?", [recordName], { $0.blobOrNil(0) }) ?? nil else { return nil }
    return SystemFields.unpack(packed)
  }

  /// 本机推送过的每条记录：记录名 → 表与推送时的修改时间。按版本对账时，推送过而服务器上已没有的就是在别处删掉了。
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

  /// 发送者读出 payload 后，在同一事务里核对该版仍在并保留发送权；与撤回互斥。
  /// 若读取后已撤回或改写，旧 payload 不能交出，发送者按新的库事实重新挑选。
  package func reserveDeliveryPayload(_ id: String, modifiedAt: Int64) throws -> Bool {
    try write {
      guard try db.first("SELECT 1 FROM deliveryRequests WHERE id = ? AND modifiedAt = ?", [id, modifiedAt], { _ in true }) != nil else { return false }
      try noteSentVersions([(id, .deliveryRequests, modifiedAt)])
      return true
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

  /// 服务器已接受这些记录（上传结果里的那一版，与系统字段归档）：记下系统字段与被推送版本的修改时间，一批一个事务。之后再改才会重新变成待推送。
  /// 上传一次只有一批在路上，结果按发出的先后回来。
  ///
  /// 你发出的话的那条消息（带请求标识，`PiChatMessage.deliveryID`）上了服务器，同一事务里收走它的投送请求（写对话时已记为送到，`applyTranscript`）。
  /// 不在写对话时收：请求的删除随回执马上传，消息走后台那一路、要等合并窗口与前面的批次，别的设备会先收到删除、气泡就空着。
  /// 服务器上删除排在消息之后，拉到删除时消息已经在了。
  package func markPushed(_ pushed: [(row: SyncRow, systemFields: Data)]) throws {
    guard !pushed.isEmpty else { return }
    let messages = JSONColumn.encode(pushed.filter { $0.row.table == .piMessages }.map(\.row.id))
    let deletedMeanwhile = try write {
      try db.run(
        """
        DELETE FROM deliveryRequests WHERE mode = '\(DeliveryMode.send.rawValue)'
          AND id IN (SELECT deliveryID FROM piMessages WHERE id IN (SELECT value FROM json_each(?)) AND deliveryID IS NOT NULL)
        """, [messages])
      return try pushed.compactMap { row, systemFields -> String? in
        try setMetadata(row.table, row.id, systemFields, pushed: row.modifiedAt)
        // 通知标志随这次上传送出，之后不能再被本机别的改动带上去（见 `PiStateRecorder`）；不动修改时间，不会让记录重新待推送
        if Table.notifyFlagged.contains(row.table), let sent = row.fields["notify"], sent != .null {
          try db.run("UPDATE \(row.table.rawValue) SET notify = NULL WHERE id = ? AND notify = ?", [row.id, sent])
        }
        return try db.first("SELECT 1 FROM \(row.table.rawValue) WHERE id = ?", [row.id]) { _ in true } == nil ? row.id : nil
      }
    }
    // 上传途中本机删掉了它：删的那次提交时服务器还没收下、算不上待推送的删除，这次记下元数据才是，提交的却只是元数据表，增量里没有它
    if !deletedMeanwhile.isEmpty { syncChanged(PendingSync(saves: [], deletes: deletedMeanwhile), in: []) }
  }

  /// 服务器上已没有这些记录（删除已确认、或本来就不存在）：忘掉它们的元数据。
  /// 数据表里还有的，因此重新变成待上传。
  package func dropSyncMetadata(_ recordNames: [String]) throws {
    guard !recordNames.isEmpty else { return }
    try write {
      for name in recordNames { try db.run("DELETE FROM syncRecords WHERE recordName = ?", [name]) }
    }
  }

  /// 同步的本机状态（同步区令牌、上次的账号）；nil 是删掉。
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

  /// 忘掉所有服务器元数据与同步状态：本机的每条同步记录重新变成待上传（新账号、云端数据被清除后重传）。
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
}
