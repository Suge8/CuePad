import Foundation

/// CuePad 的 SQLite 唯一事实源（系统 SQLite3）。App 与命令行各开一个连接写同一个库，提交后经跨进程通知互相唤醒。
///
/// 读：`projects()`、`cards(in:)` 等查询；界面用 `observe` 订阅表变更并重读，不在内存里复制状态。
/// 界面的第一帧要用的值在主线程当场读（`snapshot`），再从它接着订阅（`observe(from:)`）：页面不先排一帧空的、读到再换。
/// 写：每个写方法是一个事务，提交后向订阅者发布一次变更。
///
/// 跑在自己的串行队列上：不占并发线程池（SQLite 的读写是阻塞的）。另有两个只读连接，WAL 下读不等写：
/// - 主线程当场读（`reader`），就在主线程上，不排在队列里那些读写后面——发消息、同步写入时新出现的行当场读，不让主线程等；
/// - 订阅的重读（`rereader`），在自己的队列上：每次提交叫醒的整批重读不挡在写入与同步（拉取读令牌、应用、记账）前面。
///   2026-10-24 复现：两者同在一条队列时，被节流的进程里这条队列 89% 的时间在重读，拉取读令牌排了 26–70 秒。
public actor CueStore {
  let db: SQLite
  private nonisolated let queue: DispatchSerialQueue?
  private nonisolated let executor: UnownedSerialExecutor
  public nonisolated var unownedExecutor: UnownedSerialExecutor { executor }
  /// 主线程当场读用的只读连接（`snapshot`）；只读连接自己的是 nil。
  nonisolated let reader: CueStore?
  /// 订阅重读用的只读连接（`observe`），在自己的队列上；只读连接自己的是 nil。
  nonisolated let rereader: CueStore?
  /// 订阅者与提交序号：提交在本队列上登记，重读在 `rereader` 上收窄。
  nonisolated let subscriptions = Subscriptions()
  /// 图片文件的读写（`AttachmentFiles`）；不经过 actor，界面可并发调用。
  public nonisolated let files: AttachmentFiles
  /// 随时间变的读（`expire(at:)` 的到点重读、Mac 在不在线）用的时钟（你的话等没等过时限归 App 的 `SpeechClock`）；测试换成手动推进的。写下的时刻仍盖真实时间（`Date.stamp`）。
  public nonisolated let timing: Timing
  /// 这次读的结果到什么时候会随时间变（`expire(at:)`）：订阅到点重读。
  var readExpiry: Date?
  /// 订阅的这次读只依赖其中一部分行的表（`narrow`，同一张表可收窄几次）；不在订阅的一次读里为 nil，什么都不记。
  var readScopes: [Table: [RowScope]]?
  private var syncSubscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
  /// 可能让记录变成待推送的提交数（本连接让记录变成待推送的提交、别的进程的任何提交），与最近这些提交各自的增量
  /// （nil：范围不明，如别的进程的提交）：发送者确定没有剩下的待推送之后，只复查其后的提交碰过的记录（`pendingSync(since:)`）。
  private(set) var syncGeneration = 0
  private(set) var syncDeltas: [(generation: Int, delta: PendingSync?)] = []
  /// 增量只记最近这么多次：没有发送者（命令行、隔离库）时不越攒越多；离线攒得更多的，恢复后全量推导一次。
  private static let syncDeltaLimit = 256
  private let notificationNames: [Table: String]
  private let changeListener: ChangeListener?
  /// 每张表上次收到通知时本连接的 `PRAGMA data_version`（`externalChangeNotified`）。
  private var seenVersions: [Table: Int64]

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
    let names = ChangeNotification.names(forDatabase: url)
    let listener = ChangeListener(names: names)
    self.queue = queue
    executor = queue.asUnownedSerialExecutor()
    reader = try CueStore(reading: location, timing: timing, on: nil)
    rereader = try CueStore(reading: location, timing: timing, on: DispatchSerialQueue(label: "CueStore.rereads", qos: .userInitiated))
    db = connection
    self.timing = timing
    files = Self.files(of: location)
    notificationNames = names
    changeListener = listener
    let dataVersion = try connection.first("PRAGMA data_version") { $0.int(0) } ?? 0
    seenVersions = Dictionary(uniqueKeysWithValues: Table.allCases.map { ($0, dataVersion) })
    Task { [weak self, events = listener.events] in
      for await _ in events { await self?.externalChangeNotified() }
    }
  }

  /// 只读连接：跑在 `queue` 上，nil 是主线程；不收跨进程通知（订阅都在本体上）。
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
    notificationNames = [:]
    changeListener = nil
    seenVersions = [:]
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

  /// 收到按表的通知：只叫醒读这些表的订阅者。通知里也有本进程自己的（本连接的提交已当场叫醒过）：一张表上次收到通知以来
  /// 本连接的 `data_version` 没变（别的连接都没提交过）就是自己的，略过。别的进程提交之后才 post，所以它的通知第一次被处理时，
  /// 这张表记着的版本一定早于那次提交、和此刻的不同，不会漏；那期间别的进程只改了别的表时会多叫醒一次。
  /// 碰了同步表的另告诉同步订阅者（范围不明，发送者全量推导一次）。
  private func externalChangeNotified() {
    guard let posted = changeListener?.drain(), !posted.isEmpty else { return }
    let version = try? db.first("PRAGMA data_version") { $0.int(0) }
    let changed = posted.filter { version == nil || seenVersions[$0] != version }
    for table in posted { seenVersions[table] = version }
    guard !changed.isEmpty else { return }
    for subscriber in subscriptions.committed(changed) { subscriber.signal.yield() }
    if !changed.isDisjoint(with: Table.synced) { syncChanged(nil) }
  }

  // MARK: 内部：事务与通用行读写

  /// 资料库队列此刻要排多久：投一件空活，到它开始执行（停摆打点，App 的 `holdActivityWhilePolling`）。
  public nonisolated func queueDelay() async -> Duration {
    await waited(since: .now)
  }

  private func waited(since posted: ContinuousClock.Instant) -> Duration { .now - posted }

  /// 一个写事务；提交后通知订阅者，并把改动的同步记录交给同步订阅者。
  func write<T>(_ body: () throws -> T) throws -> T {
    let (result, changes) = try db.transaction(body)
    let tables = Set(changes.tables.compactMap(Table.init(rawValue:)))
    if !tables.isEmpty {
      for subscriber in subscriptions.committed(tables) where touches(tables, changes, reading: subscriber.tables, scopes: subscriber.scopes) {
        subscriber.signal.yield()
      }
      for table in tables { ChangeNotification.post(notificationNames[table]!) }
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
      WHERE \(condition) ORDER BY \(orderBy) LIMIT ? OFFSET ?
      """
    let arguments = arguments + [limit, offset]
    guard R.self is any AwaitsServer.Type else { return try db.query(sql, arguments) { R(row: $0) } }
    // 带服务器状态的记录：同步元数据不按整表依赖，只登记读到的还没发出的那几句
    let rows = try db.untracked(.syncRecords) { try db.query(sql, arguments) { R(row: $0) } }
    try dependOnUnsent(rows.compactMap { ($0 as? any AwaitsServer)?.unsentName })
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
