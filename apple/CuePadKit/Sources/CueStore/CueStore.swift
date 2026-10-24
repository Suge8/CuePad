import Foundation
import Synchronization

/// CuePad 的 SQLite 唯一事实源（系统 SQLite3）。App 与命令行各开一个连接写同一个库，提交后经跨进程通知互相唤醒。
///
/// 读：`projects()`、`cards(in:)` 等查询；界面用 `observe` 订阅表变更并重读，不在内存里复制状态。
/// 界面的第一帧要用的值在主线程当场读（`snapshot`），再从它接着订阅（`observe(from:)`）：页面不先排一帧空的、读到再换。
/// 写：每个写方法是一个事务，提交后向订阅者发布一次变更。
///
/// 跑在自己的串行队列上：不占并发线程池（SQLite 的读写是阻塞的）。主线程当场读走另一个只读连接（`reader`），它就在主线程上：
/// WAL 下读不等写，也不排在队列里那些读写后面——发消息、同步写入时新出现的行当场读，不让主线程等。
public actor CueStore {
  let db: SQLite
  private nonisolated let queue: DispatchSerialQueue?
  private nonisolated let executor: UnownedSerialExecutor
  public nonisolated var unownedExecutor: UnownedSerialExecutor { executor }
  /// 主线程当场读用的只读连接（`snapshot`）；它自己的是 nil（读它自己）。
  nonisolated let reader: CueStore?
  /// 提交过几次（本连接的写事务、别的进程的提交）：从快照接着订阅时据此知道其间有没有写入。快照在主线程上取它，所以是原子的。
  nonisolated let commits = Atomic(0)
  /// 图片文件的读写（`AttachmentFiles`）；不经过 actor，界面可并发调用。
  public nonisolated let files: AttachmentFiles
  /// 随时间变的读（`expire(at:)` 的到点重读、Mac 在不在线）用的时钟（你的话等没等过时限归 App 的 `SpeechClock`）；测试换成手动推进的。写下的时刻仍盖真实时间（`Date.stamp`）。
  public nonisolated let timing: Timing
  var subscribers: [UUID: (tables: Set<Table>, scopes: [Table: RowScope], signal: AsyncStream<Void>.Continuation)] = [:]
  /// 这次读的结果到什么时候会随时间变（`expire(at:)`）：订阅到点重读。
  var readExpiry: Date?
  /// 这次读只依赖其中一部分行的表（`narrow`）；同一张表收窄了不止一次的记进 `readWhole`，按整表依赖。
  var readScopes: [Table: RowScope] = [:]
  var readWhole: Set<Table> = []
  /// 这次读到的还没发出的话（`noteUnsent`）：订阅只在它们被服务器收下时因同步元数据叫醒。
  var readUnsent: Set<String> = []
  private var syncSubscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
  /// 可能让记录变成待推送的提交数（本连接让记录变成待推送的提交、别的进程的任何提交），与最近这些提交各自的增量
  /// （nil：范围不明，如别的进程的提交）：发送者确定没有剩下的待推送之后，只复查其后的提交碰过的记录（`pendingSync(since:)`）。
  private(set) var syncGeneration = 0
  private(set) var syncDeltas: [(generation: Int, delta: PendingSync?)] = []
  /// 增量只记最近这么多次：没有发送者（命令行、隔离库）时不越攒越多；离线攒得更多的，恢复后全量推导一次。
  private static let syncDeltaLimit = 256
  private let notificationName: String
  private let changeListener: ChangeListener?
  private var lastDataVersion: Int64

  public init(location: LibraryLocation, timing: Timing = .system) throws {
    let url = location.databaseURL
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let connection = try SQLite(path: url.path)
    try connection.exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL")
    let version = try connection.first("PRAGMA user_version") { Int($0.int(0)) } ?? 0
    if version == 0 {
      _ = try connection.transaction {
        try connection.exec(Schema.create)
        try connection.exec("PRAGMA user_version = \(Schema.version)")
      }
    } else if version < Schema.baseVersion {
      throw CueStoreError.schemaTooOld(version)
    } else if version < Schema.version {
      _ = try connection.transaction {
        for upgrade in Schema.upgrades[(version - Schema.baseVersion)...] { try upgrade.run(connection) }
        try connection.exec("PRAGMA user_version = \(Schema.version)")
      }
      try Schema.reclaim(connection)
    } else if version != Schema.version {
      throw CueStoreError.unsupportedSchemaVersion(version)
    }
    let queue = DispatchSerialQueue(label: "CueStore", qos: .userInitiated)
    let listener = ChangeListener(name: ChangeNotification.name(forDatabase: url))
    self.queue = queue
    executor = queue.asUnownedSerialExecutor()
    reader = try CueStore(reading: location, timing: timing)
    db = connection
    self.timing = timing
    files = Self.files(of: location)
    notificationName = ChangeNotification.name(forDatabase: url)
    changeListener = listener
    lastDataVersion = try connection.first("PRAGMA data_version") { $0.int(0) } ?? 0
    Task { [weak self, events = listener.events] in
      for await _ in events { await self?.externalChangeNotified() }
    }
  }

  /// 主线程当场读用的连接：只读、跑在主线程上，不收跨进程通知（订阅都在本体上）。
  private init(reading location: LibraryLocation, timing: Timing) throws {
    let url = location.databaseURL
    let connection = try SQLite(path: url.path)
    try connection.exec("PRAGMA query_only = ON")
    queue = nil
    executor = MainActor.sharedUnownedExecutor
    reader = nil
    db = connection
    self.timing = timing
    files = Self.files(of: location)
    notificationName = ChangeNotification.name(forDatabase: url)
    changeListener = nil
    lastDataVersion = 0
  }

  private static func files(of location: LibraryLocation) -> AttachmentFiles {
    AttachmentFiles(directory: location.directory.appending(path: "Attachments", directoryHint: .isDirectory), caches: location.caches)
  }

  /// 这个版本能打开的库结构版本范围（`PRAGMA user_version`）；失败页据此区分"库是更新版本建的""库是更早版本建的"与别的失败。
  public static var supportedSchemaVersions: ClosedRange<Int> { Schema.baseVersion...Schema.version }

  /// 库文件现在的结构版本，不改库；文件不存在或读不出来为 nil。
  public static func schemaVersion(of url: URL) -> Int? {
    guard FileManager.default.fileExists(atPath: url.path), let connection = try? SQLite(path: url.path) else { return nil }
    return (try? connection.first("PRAGMA user_version") { Int($0.int(0)) }) ?? nil
  }

  /// 收到别的进程的通知：确有别的连接提交过才算外部变更，所有订阅者整体重读（不猜是哪张表）。
  private func externalChangeNotified() {
    guard let version = try? db.first("PRAGMA data_version", [], { $0.int(0) }), version != lastDataVersion else { return }
    lastDataVersion = version
    commits.add(1, ordering: .releasing)
    for subscriber in subscribers.values { subscriber.signal.yield() }
    syncChanged(nil)
  }

  // MARK: 内部：事务与通用行读写

  /// 一个写事务；提交后通知订阅者，并把改动的同步记录交给同步订阅者。
  func write<T>(_ body: () throws -> T) throws -> T {
    let (result, changes) = try db.transaction(body)
    let tables = Set(changes.tables.compactMap(Table.init(rawValue:)))
    if !tables.isEmpty {
      commits.add(1, ordering: .releasing)
      ChangeNotification.post(notificationName)
    }
    for (_, subscriber) in subscribers where touches(tables, changes, reading: subscriber.tables, scopes: subscriber.scopes) {
      subscriber.signal.yield()
    }
    if !tables.isDisjoint(with: Table.synced) {
      // 只有让记录变成待推送的提交才算（记账、应用远端版本这类不会）；算不出增量时照算
      let delta = try? pendingSync(in: changes)
      if delta.map({ !$0.saves.isEmpty || !$0.deletes.isEmpty }) ?? true { syncChanged(delta) }
    }
    return result
  }

  func syncChanged(_ delta: PendingSync?) {
    syncGeneration += 1
    syncDeltas.append((syncGeneration, delta))
    if syncDeltas.count > Self.syncDeltaLimit { syncDeltas.removeFirst() }
    for subscriber in syncSubscribers.values { subscriber.yield() }
  }

  /// 同步订阅：本连接的提交让记录变成待推送，或别的进程提交过（范围未知），就给一个信号；待推送是什么读 `pendingSync()`。
  /// 订阅在返回前已生效。
  package func syncChanges() -> AsyncStream<Void> {
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
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
      WHERE \(condition) ORDER BY \(orderBy) LIMIT \(limit) OFFSET \(offset)
      """
    guard R.self is any AwaitsServer.Type else { return try db.query(sql, arguments) { R(row: $0) } }
    // 带服务器状态的记录：同步元数据不按整表依赖，只登记读到的还没发出的那几句
    let rows = try db.untracked(.syncRecords) { try db.query(sql, arguments) { R(row: $0) } }
    noteUnsent(rows.compactMap { ($0 as? any AwaitsServer)?.unsentName })
    return rows
  }

  func find<R: Record>(_ type: R.Type, _ id: any SQLBindable) throws -> R? {
    try select(type, where: "id = ?", [id]).first
  }

  /// 返回是否真的写入了新行。
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

  /// 有这一行就按主键改 `updating` 这几列（nil 是除主键外的全部），没有就插入。
  func upsert<R: Record>(_ record: R, updating: [String]? = nil) throws {
    try db.run(Self.upsertSQL(R.table, R.columns, updating: updating), record.bindings)
  }

  static func upsertSQL(_ table: Table, _ columns: [String], updating: [String]? = nil) -> String {
    """
    INSERT INTO \(table.rawValue) (\(columns.joined(separator: ", "))) VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))
    ON CONFLICT(id) DO UPDATE SET \((updating ?? Array(columns.dropFirst())).map { "\($0) = excluded.\($0)" }.joined(separator: ", "))
    """
  }

  /// 按主键覆盖除主键外的所有列。
  func update<R: Record>(_ record: R) throws {
    let assignments = R.columns.dropFirst().map { "\($0) = ?" }.joined(separator: ", ")
    try db.run(
      "UPDATE \(R.table.rawValue) SET \(assignments) WHERE id = ?",
      Array(record.bindings.dropFirst()) + [record.bindings[0]])
  }
}
