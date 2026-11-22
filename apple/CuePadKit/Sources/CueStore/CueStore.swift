import Foundation
import OSLog

public actor CueStore {
  let db: SQLite
  nonisolated let queue: DispatchSerialQueue?
  private nonisolated let executor: UnownedSerialExecutor
  public nonisolated var unownedExecutor: UnownedSerialExecutor { executor }
  nonisolated let reader: CueStore?
  nonisolated let rereader: CueStore?
  nonisolated let subscriptions = Subscriptions()
  public nonisolated let files: AttachmentFiles
  public nonisolated let libraryDirectory: URL
  public nonisolated let databasePath: String
  public nonisolated let timing: Timing
  var readExpiry: Date?
  var readScopes: [Table: [RowScope]]?
  private var syncSubscribers: [UUID: AsyncStream<SyncChange>.Continuation] = [:]
  private(set) var syncGeneration = 0
  private(set) var syncDeltas: [(generation: Int, delta: PendingSync?)] = []
  private static let syncDeltaLimit = 256
  private let notificationNames: [Table: String]
  private let changeListener: ChangeListener?
  private var seenVersions: [Table: Int64]

  public init(location: LibraryLocation, timing: Timing = .system) throws {
    let url = location.databaseURL
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let connection = try SQLite(path: url.path)
    try connection.exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL")
    if try Self.userVersion(connection) != Schema.version { try Self.migrate(connection) }
    try connection.exec(Self.guards)
    try connection.exec(Self.taskSessionEvents)
    let queue = DispatchSerialQueue(label: "CueStore", qos: .userInitiated)
    let names = ChangeNotification.names(forDatabase: url)
    let listener = ChangeListener(names: names)
    self.queue = queue
    executor = queue.asUnownedSerialExecutor()
    reader = try CueStore(reading: location, timing: timing, on: nil)
    rereader = try CueStore(reading: location, timing: timing, on: DispatchSerialQueue(label: "CueStore.rereads", qos: .userInitiated))
    db = connection
    self.timing = timing
    files = Self.files(of: location)
    libraryDirectory = location.directory
    databasePath = location.databaseURL.path
    notificationNames = names
    changeListener = listener
    let dataVersion = try connection.first("PRAGMA data_version") { $0.int(0) } ?? 0
    seenVersions = Dictionary(uniqueKeysWithValues: Table.allCases.map { ($0, dataVersion) })
    Task { [weak self, events = listener.events] in
      for await _ in events { await self?.externalChangeNotified() }
    }
  }

  private static func userVersion(_ connection: SQLite) throws -> Int {
    try connection.first("PRAGMA user_version") { Int($0.int(0)) } ?? 0
  }

  private static func migrate(_ connection: SQLite) throws {
    _ = try connection.transaction {
      let version = try userVersion(connection)
      if version == Schema.version { return }
      if version == 0 {
        try connection.exec(Schema.create)
      } else {
        if version < Schema.baseVersion { throw CueStoreError.schemaTooOld(version) }
        if version > Schema.version { throw CueStoreError.unsupportedSchemaVersion(version) }
        for step in Schema.upgrades[(version - Schema.baseVersion)...] { try connection.exec(step) }
        if version < Schema.tiersArrived { try Schema.adoptCueTurns(connection) }
      }
      try connection.exec("PRAGMA user_version = \(Schema.version)")
    }
  }

  private init(reading location: LibraryLocation, timing: Timing, on queue: DispatchSerialQueue?) throws {
    let connection = try SQLite(path: location.databaseURL.path)
    try connection.exec("PRAGMA query_only = ON")
    self.queue = queue
    executor = queue?.asUnownedSerialExecutor() ?? MainActor.sharedUnownedExecutor
    reader = nil
    rereader = nil
    db = connection
    self.timing = timing
    files = Self.files(of: location)
    libraryDirectory = location.directory
    databasePath = location.databaseURL.path
    notificationNames = [:]
    changeListener = nil
    seenVersions = [:]
  }

  private static func files(of location: LibraryLocation) -> AttachmentFiles {
    AttachmentFiles(library: location.directory, caches: location.caches)
  }

  public static var supportedSchemaVersions: ClosedRange<Int> { Schema.baseVersion...Schema.version }
  public static var peerFloor: Int { Schema.peerFloor }

  public static func schemaVersion(of url: URL) -> Int? {
    guard FileManager.default.fileExists(atPath: url.path), let connection = try? SQLite(path: url.path) else { return nil }
    return (try? connection.first("PRAGMA user_version") { Int($0.int(0)) }) ?? nil
  }

  private func externalChangeNotified() {
    guard let posted = changeListener?.drain(), !posted.isEmpty else { return }
    let version = try? db.first("PRAGMA data_version") { $0.int(0) }
    let changed = posted.filter { version == nil || seenVersions[$0] != version }
    for table in posted { seenVersions[table] = version }
    guard !changed.isEmpty else { return }
    for subscriber in subscriptions.committed(changed) { subscriber.signal.yield() }
    if !changed.isDisjoint(with: Table.synced) {
      syncChanged(nil, in: changed, urgent: changed.contains { if case .gathered = Table.live[$0] { false } else { Table.live[$0] != nil } })
    }
  }

  public nonisolated func queueDelay() async -> Duration {
    await waited(since: .now)
  }

  private func waited(since posted: ContinuousClock.Instant) -> Duration { .now - posted }

  func write<T>(_ body: () throws -> T) throws -> T {
    let (result, changes) = try db.transaction {
      let value = try body()
      try reconcileTaskSessionEvents()
      return value
    }
    let tables = Set(changes.tables.compactMap(Table.init(rawValue:)))
    if !tables.isEmpty {
      for subscriber in subscriptions.committed(tables) where touches(tables, changes, reading: subscriber.tables, scopes: subscriber.scopes) {
        subscriber.signal.yield()
      }
      for table in tables { ChangeNotification.post(notificationNames[table]!) }
    }
    if !tables.isDisjoint(with: Table.synced) || tables.contains(.syncRecords) {
      let delta = Self.logged("算不出待推送增量") { try pendingSync(in: changes) }
      let deleted = !changes.deletedFrom.isDisjoint(with: Table.synced.map(\.rawValue))
      if delta.map({ !$0.saves.isEmpty || !$0.deletes.isEmpty || deleted }) ?? true {
        syncChanged(delta, in: tables, urgent: delta.flatMap { delta in Self.logged("算不出要不要马上传") { try urgent(among: delta) } } ?? true)
      }
    }
    return result
  }

  private static let syncLog = Logger(subsystem: AppIdentity.id, category: "sync")

  private static func logged<T>(_ what: String, _ body: () throws -> T) -> T? {
    do { return try body() } catch {
      syncLog.error("\(what, privacy: .public)：\(String(describing: error), privacy: .public)")
      return nil
    }
  }

  func syncChanged(_ delta: PendingSync?, in tables: Set<Table>, urgent: Bool) {
    syncGeneration += 1
    syncDeltas.append((syncGeneration, delta))
    if syncDeltas.count > Self.syncDeltaLimit { syncDeltas.removeFirst() }
    for subscriber in syncSubscribers.values { subscriber.yield(SyncChange(tables: tables, urgent: urgent)) }
  }

  package func syncChanges() -> AsyncStream<SyncChange> {
    let (stream, continuation) = AsyncStream<SyncChange>.makeStream()
    let token = UUID()
    syncSubscribers[token] = continuation
    continuation.onTermination = { _ in Task { await self.removeSyncSubscriber(token) } }
    return stream
  }

  private func removeSyncSubscriber(_ token: UUID) { syncSubscribers[token] = nil }

  func select<R: Record>(
    _ type: R.Type, where condition: String = "1", _ arguments: [any SQLBindable] = [],
    orderBy: String = "rowid", limit: Int = -1, offset: Int = 0
  ) throws -> [R] {
    let sql = """
      SELECT \(R.selection) FROM \(R.table.rawValue)
      WHERE \(condition) ORDER BY \(orderBy) LIMIT ? OFFSET ?
      """
    let arguments = arguments + [limit, offset]
    guard R.self is any AwaitsServer.Type else { return try db.query(sql, arguments) { R(row: $0) } }
    let rows = try db.untracked(.syncRecords) { try db.query(sql, arguments) { R(row: $0) } }
    try dependOnUnsent(rows.compactMap { ($0 as? any AwaitsServer)?.unsentName })
    return rows
  }

  func find<R: Record>(_ type: R.Type, _ id: any SQLBindable) throws -> R? {
    try select(type, where: "id = ?", [id]).first
  }

  @discardableResult
  func insert<R: Record>(_ record: R, ignoringExisting: Bool = false) throws -> Bool {
    let placeholders = R.columns.map { _ in "?" }.joined(separator: ", ")
    try db.run(
      """
      INSERT INTO \(R.table.rawValue) (\(R.columns.joined(separator: ", "))) VALUES (\(placeholders))
      \(ignoringExisting ? "ON CONFLICT(id) DO NOTHING" : "")
      """, record.bindings)
    return db.changes > 0
  }

  func upsert<R: Record>(_ record: R, updating: [String]? = nil) throws {
    try db.run(Self.upsertSQL(R.table, R.columns, updating: updating), record.bindings)
  }

  static func upsertSQL(_ table: Table, _ columns: [String], updating: [String]? = nil) -> String {
    """
    INSERT INTO \(table.rawValue) (\(columns.joined(separator: ", "))) VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))
    ON CONFLICT(id) DO UPDATE SET \((updating ?? Array(columns.dropFirst())).map { "\($0) = excluded.\($0)" }.joined(separator: ", "))
    """
  }

  func update<R: Record>(_ record: R) throws {
    let assignments = R.columns.dropFirst().map { "\($0) = ?" }.joined(separator: ", ")
    try db.run(
      "UPDATE \(R.table.rawValue) SET \(assignments) WHERE id = ?",
      Array(record.bindings.dropFirst()) + [record.bindings[0]])
  }
}
