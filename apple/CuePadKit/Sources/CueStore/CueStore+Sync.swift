import Foundation

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

package struct SyncChange: Sendable {
  package var tables: Set<Table>
  package var urgent: Bool
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

  func urgent(among delta: PendingSync) throws -> Bool {
    let saves = Dictionary(grouping: delta.saves, by: \.table).mapValues { $0.map(\.id) }
    for (table, urgency) in Table.live {
      guard let ids = saves[table] else { continue }
      switch urgency {
      case .always: return true
      case .when(let condition):
        if try !pendingSaves(table, where: "(\(condition)) AND t.id IN (SELECT value FROM json_each(?))", [JSONColumn.encode(ids)]).isEmpty { return true }
      case .gathered: continue
      }
    }
    guard !delta.deletes.isEmpty else { return false }
    return try db.first(
      "SELECT 1 FROM syncRecords WHERE recordName IN (SELECT value FROM json_each(?)) AND recordType IN (SELECT value FROM json_each(?))",
      [JSONColumn.encode(delta.deletes), JSONColumn.encode(Table.live.keys.map(\.rawValue))]) { _ in true } != nil
  }

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

  package func pendingSync(
    since generation: Int?, in tables: [Table], urgentOnly: Bool = false, newestFirst: Bool
  ) throws -> (pending: PendingSync, generation: Int) {
    var saves: [(key: SyncKey, modifiedAt: Int64)] = [], deletes: [String] = []
    let touched = generation.flatMap(touched(after:))
    let names = touched.map { Set($0.deletes).sorted() }
    for table in tables {
      let condition: String
      switch (urgentOnly, Table.live[table]) {
      case (false, _), (true, .always), (true, .gathered): condition = "1"
      case (true, .when(let urgent)): condition = urgent
      case (true, nil): continue
      }
      if let touched {
        let ids = Set(touched.saves.filter { $0.table == table }.map(\.id)).sorted()
        if !ids.isEmpty {
          saves += try pendingVersions(table, where: "(\(condition)) AND t.id IN (SELECT value FROM json_each(?))", [JSONColumn.encode(ids)])
        }
        if let names, !names.isEmpty { deletes += try pendingDeletes(table, among: names) }
      } else {
        saves += try pendingVersions(table, where: condition, scanning: true)
        deletes += try pendingDeletes(table)
      }
    }
    if newestFirst { saves.sort { $0.modifiedAt > $1.modifiedAt } }
    return (PendingSync(saves: saves.map(\.key), deletes: deletes), syncGeneration)
  }

  package func pendingSync(among names: Set<String>, in tables: [Table] = Table.synced) throws -> PendingSync {
    let sorted = names.sorted(), ids = JSONColumn.encode(sorted)
    var pending = PendingSync(saves: [], deletes: [])
    for table in tables {
      pending.saves += try pendingSaves(table, where: "t.id IN (SELECT value FROM json_each(?))", [ids])
      pending.deletes += try pendingDeletes(table, among: sorted)
    }
    return pending
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

  private func pendingSaves(
    _ table: Table, where condition: String, _ arguments: [any SQLBindable] = [], scanning: Bool = false
  ) throws -> [SyncKey] {
    try pendingVersions(table, where: condition, arguments, scanning: scanning).map(\.key)
  }

  private func pendingVersions(
    _ table: Table, where condition: String, _ arguments: [any SQLBindable] = [], scanning: Bool = false
  ) throws -> [(key: SyncKey, modifiedAt: Int64)] {
    try db.query(
      """
      SELECT t.id, t.modifiedAt FROM \(table.rawValue) t \(scanning ? "INDEXED BY \(table.rawValue)_modified" : "")
      LEFT JOIN syncRecords s INDEXED BY syncRecords_pushed ON s.recordName = t.id
      WHERE (\(condition)) AND (s.pushedModifiedAt IS NULL OR t.modifiedAt > s.pushedModifiedAt) ORDER BY t.rowid
      """, arguments
    ) { (SyncKey(table: table, id: $0.text(0)), $0.int(1)) }
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

  package func markPushed(_ pushed: [(row: SyncRow, systemFields: Data, serverAt: Date?)]) throws {
    guard !pushed.isEmpty else { return }
    let messages = JSONColumn.encode(pushed.filter { $0.row.table == .piMessages }.map(\.row.id))
    try write {
      for (row, systemFields, serverAt) in pushed {
        try setMetadata(row.table, row.id, systemFields, pushed: row.modifiedAt)
        if row.table == .deliveryRequests, let serverAt {
          try db.run("UPDATE deliveryRequests SET serverAt = ? WHERE id = ? AND serverAt IS NULL", [serverAt, row.id])
        }
        if Table.notifyFlagged.contains(row.table), let sent = row.fields["notify"], sent != .null {
          try db.run("UPDATE \(row.table.rawValue) SET notify = NULL WHERE id = ? AND notify = ?", [row.id, sent])
        }
      }
      let deliveries = try db.query(
        "SELECT deliveryID FROM piMessages WHERE id IN (SELECT value FROM json_each(?)) AND deliveryID IS NOT NULL", [messages]) { $0.uuid(0) }
      try removeExpiredDeliveries(among: Set(deliveries), at: timing.now())
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
      try db.run("DELETE FROM syncState WHERE key NOT LIKE 'capture:%'")
    }
  }

  package func eraseSyncedData() throws {
    try write {
      for table in Table.synced { try db.run("DELETE FROM \(table.rawValue)") }
      try db.run("DELETE FROM projectDirectories")
      try db.run("DELETE FROM syncRecords")
      try db.run("DELETE FROM syncState")
      try db.exec(Schema.defaultProject)
      try files.removeAll()
    }
  }
}
