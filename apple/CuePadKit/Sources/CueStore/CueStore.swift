import Foundation

/// CuePad 的 SQLite 唯一事实源（系统 SQLite3）。App 与命令行各开一个连接写同一个库，提交后经跨进程通知互相唤醒。
///
/// 读：`projects()`、`cards(in:)` 等查询；界面用 `observe` 订阅表变更并重读，不在内存里复制状态。
/// 写：每个写方法是一个事务，提交后向订阅者发布一次变更。
public actor CueStore {
  let db: SQLite
  /// 图片文件的读取（原图、缩略图）；不经过 actor，界面可并发调用。写入用 `addImage`。
  public nonisolated let files: AttachmentFiles
  private var subscribers: [UUID: (tables: Set<Table>, signal: AsyncStream<Void>.Continuation)] = [:]
  private var syncSubscribers: [UUID: AsyncStream<PendingSync?>.Continuation] = [:]
  private let notificationName: String
  private let changeListener: ChangeListener
  private var lastDataVersion: Int64
  /// 这个连接是哪台 Mac（`ownSessions`）：它写的会话记录由它挂到任务上；手机与命令行为 nil。
  var sessionHost: String?

  public init(url: URL) throws {
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
    } else if version != Schema.version {
      throw CueStoreError.unsupportedSchemaVersion(version)
    }
    db = connection
    files = AttachmentFiles(directory: url.deletingLastPathComponent().appending(path: "Attachments", directoryHint: .isDirectory))
    notificationName = ChangeNotification.name(forDatabase: url)
    changeListener = ChangeListener(name: notificationName)
    lastDataVersion = try connection.first("PRAGMA data_version") { $0.int(0) } ?? 0
    Task { [weak self, events = changeListener.events] in
      for await _ in events { await self?.externalChangeNotified() }
    }
  }

  /// 这个版本能打开的库结构版本范围（`PRAGMA user_version`）；失败页据此区分"库是更新版本建的""库是更早版本建的"与别的失败。
  public static var supportedSchemaVersions: ClosedRange<Int> { Schema.baseVersion...Schema.version }

  /// 库文件现在的结构版本，不改库；文件不存在或读不出来为 nil。
  public static func schemaVersion(of url: URL) -> Int? {
    guard FileManager.default.fileExists(atPath: url.path), let connection = try? SQLite(path: url.path) else { return nil }
    return (try? connection.first("PRAGMA user_version") { Int($0.int(0)) }) ?? nil
  }

  /// 按资料库位置打开。
  public init(location: LibraryLocation) throws {
    try self.init(url: location.databaseURL)
  }

  /// 收到别的进程的通知：确有别的连接提交过才算外部变更，所有订阅者整体重读（不猜是哪张表）。
  private func externalChangeNotified() {
    guard let version = try? db.first("PRAGMA data_version", [], { $0.int(0) }), version != lastDataVersion else { return }
    lastDataVersion = version
    for subscriber in subscribers.values { subscriber.signal.yield() }
    for subscriber in syncSubscribers.values { subscriber.yield(nil) }
  }

  // MARK: 观察

  /// 订阅：先产出一次当前值，之后每当 `read` 读到的表被提交的写事务改动就重读并产出。依赖的表由读取本身决定
  /// （每次读完按它实际读到的表更新，随数据走不同分支也对），调用处不另声明；这是订阅的唯一写法——
  /// 只要"变了就叫我"的也读一个会跟着变的值（计数、版本、列表），不单独订阅表。
  /// 突发的多次写入会合并为一次重读。`read` 在 store 的隔离域内执行，可直接调用查询方法：
  /// `store.observe { try $0.cards(in: id) }`
  /// 订阅以表为粒度：别的行改动同一张表也会重读，但结果和上一次一样就不产出——比较只在读取的这一侧做一次，
  /// 不把没变的数据送到主线程、也不让界面白白重算。`initial` 是调用方手里已有的值，当作"上一次"：重新订阅后第一份没变也不产出。
  public nonisolated func observe<T: Sendable & Equatable>(
    after initial: T? = nil, _ read: @escaping @Sendable (isolated CueStore) throws -> T
  ) -> AsyncThrowingStream<T, Error> {
    AsyncThrowingStream { continuation in
      let (signals, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      let task = Task {
        // 第一次读之前什么都可能改动它：先订阅全部表，读完再收窄
        let token = await self.subscribe(signal)
        signal.yield()
        do {
          var last = initial
          for await _ in signals {
            let next = try await self.run(read, token: token)
            if next == last { continue }
            last = next
            continuation.yield(next)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
        await self.unsubscribe(token)
      }
      continuation.onTermination = { _ in
        signal.finish()
        task.cancel()
      }
    }
  }

  private func subscribe(_ signal: AsyncStream<Void>.Continuation) -> UUID {
    let token = UUID()
    subscribers[token] = (Set(Table.allCases), signal)
    return token
  }

  /// 读一次，并把订阅收窄到这次实际读到的表。读与收窄在同一次 actor 执行里，其间没有写入能漏掉。
  private func run<T>(_ read: (isolated CueStore) throws -> T, token: UUID) throws -> T {
    let (value, reads) = try db.tracking { try read(self) }
    subscribers[token]?.tables = reads
    return value
  }

  private func unsubscribe(_ token: UUID) { subscribers[token] = nil }

  // MARK: 内部：事务与通用行读写

  /// 一个写事务；提交前让会话都挂在任务上（`adoptSessions`），提交后通知订阅者，并把改动的同步记录交给同步订阅者。
  func write<T>(_ body: () throws -> T) throws -> T {
    let (result, changes) = try db.transaction {
      let result = try body()
      try adoptSessions()
      return result
    }
    let tables = Set(changes.tables.compactMap(Table.init(rawValue:)))
    if !tables.isEmpty { ChangeNotification.post(notificationName) }
    for (_, subscriber) in subscribers where !subscriber.tables.isDisjoint(with: tables) {
      subscriber.signal.yield()
    }
    if !syncSubscribers.isEmpty, !tables.isDisjoint(with: Table.synced) {
      let delta = try? pendingSync(in: changes)  // 算不出增量时让订阅者全量对账
      for subscriber in syncSubscribers.values { subscriber.yield(delta) }
    }
    return result
  }

  /// 同步订阅：本连接每次提交改动了同步表，就给出这次提交中变成待推送的记录；
  /// nil 表示改动范围未知（别的进程提交过，或增量没算出来），需要全量对账（`pendingSync()`）。订阅在返回前已生效。
  package func syncChanges() -> AsyncStream<PendingSync?> {
    let (stream, continuation) = AsyncStream<PendingSync?>.makeStream()
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
    try db.query(
      """
      SELECT \(R.columns.joined(separator: ", ")) FROM \(R.table.rawValue)
      WHERE \(condition) ORDER BY \(orderBy) LIMIT \(limit) OFFSET \(offset)
      """,
      arguments
    ) { R(row: $0) }
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

  /// 按主键覆盖除主键外的所有列。
  func update<R: Record>(_ record: R) throws {
    let assignments = R.columns.dropFirst().map { "\($0) = ?" }.joined(separator: ", ")
    try db.run(
      "UPDATE \(R.table.rawValue) SET \(assignments) WHERE id = ?",
      Array(record.bindings.dropFirst()) + [record.bindings[0]])
  }
}
