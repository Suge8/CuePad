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
  private nonisolated let reader: CueStore?
  /// 提交过几次（本连接的写事务、别的进程的提交）：从快照接着订阅时据此知道其间有没有写入。快照在主线程上取它，所以是原子的。
  private nonisolated let commits = Atomic(0)
  /// 图片文件的读取（原图、缩略图）；不经过 actor，界面可并发调用。写入用 `addImage`。
  public nonisolated let files: AttachmentFiles
  /// 随时间变的读（`expire(at:)` 的到点重读、Mac 在不在线）用的时钟（你的话等没等过时限归 App 的 `SpeechClock`）；测试换成手动推进的。写下的时刻仍盖真实时间（`Date.stamp`）。
  public nonisolated let timing: Timing
  private var subscribers: [UUID: (tables: Set<Table>, signal: AsyncStream<Void>.Continuation)] = [:]
  /// 这次读的结果到什么时候会随时间变（`expire(at:)`）：订阅到点重读。
  private var readExpiry: Date?
  private var syncSubscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
  /// 可能让记录变成待推送的提交数（本连接让记录变成待推送的提交、别的进程的任何提交）：没变就说明上次推导出的待推送仍然成立，
  /// 发送者不必为确认"没有要传的"再全量推导一遍（`SyncCoordinator.nextBatch`）。
  package private(set) var syncGeneration = 0
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
    syncChanged()
  }

  // MARK: 观察

  /// 订阅：先产出一次当前值，之后每当 `read` 读到的表被提交的写事务改动就重读并产出。依赖的表由读取本身决定
  /// （每次读完按它实际读到的表更新，随数据走不同分支也对），调用处不另声明；这是订阅的唯一写法——
  /// 只要"变了就叫我"的也读一个会跟着变的值（计数、版本、列表），不单独订阅表。
  /// 结果随时间变的（读里登记了 `expire(at:)`，如 Cue 那台 Mac 算不算在线）到点也重读，不轮询。
  /// 突发的多次写入会合并为一次重读。`read` 在 store 的隔离域内执行，可直接调用查询方法：
  /// `store.observe { try $0.cards(in: id) }`
  /// 订阅以表为粒度：别的行改动同一张表也会重读，但结果和上一次一样就不产出——比较只在读取的这一侧做一次，
  /// 不把没变的数据送到主线程、也不让界面白白重算。`initial` 是调用方手里已有的值，当作"上一次"：重新订阅后第一份没变也不产出。
  public nonisolated func observe<T: Sendable & Equatable>(
    after initial: T? = nil, _ read: @escaping @Sendable (isolated CueStore) throws -> T
  ) -> AsyncThrowingStream<T, Error> {
    observe(read, reading: Set(Table.allCases), since: nil, last: initial, expiry: nil)
  }

  /// 从主线程当场读到的那份（`snapshot`）接着订阅：不重读，之后的变化照 `observe`；快照之后已有写入的，马上重读一次。
  public nonisolated func observe<T: Sendable & Equatable>(
    from snapshot: Snapshot<T>, _ read: @escaping @Sendable (isolated CueStore) throws -> T
  ) -> AsyncThrowingStream<T, Error> {
    observe(read, reading: snapshot.tables, since: snapshot.version, last: snapshot.value, expiry: snapshot.expiry)
  }

  /// 主线程上当场读一次（只读连接，不等队列）：界面第一帧要的值，读到的表与时刻一并记下，交给 `observe(from:)` 接着订阅。
  @MainActor
  public func snapshot<T: Sendable>(_ read: @Sendable (isolated CueStore) throws -> T) throws -> Snapshot<T> {
    // 先取提交数再读：其间有提交的，接着订阅时多重读一次，不会漏
    let since = commits.load(ordering: .acquiring)
    let (value, tables, expiry) = try (reader ?? self).assumeIsolated { try $0.tracked(read) }
    return Snapshot(value: value, tables: tables, version: since, expiry: expiry)
  }

  /// 订阅 `tables`（`since` 见 `subscribe`），每个信号重读一次；`last` 是第一次比较的"上一次"，`expiry` 是它到点重读的时刻。
  private nonisolated func observe<T: Sendable & Equatable>(
    _ read: @escaping @Sendable (isolated CueStore) throws -> T, reading tables: Set<Table>, since: Int?, last initial: T?, expiry firstExpiry: Date?
  ) -> AsyncThrowingStream<T, Error> {
    AsyncThrowingStream { continuation in
      let (signals, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      let task = Task {
        let token = await self.subscribe(signal, reading: tables, since: since)
        var timer: Task<Void, Never>?
        defer { timer?.cancel() }
        let timing = self.timing
        func schedule(_ expiry: Date?) {
          timer?.cancel()
          timer = expiry.map { due in
            Task {
              guard (try? await timing.sleep(.seconds(max(0, due.timeIntervalSince(timing.now()))))) != nil else { return }
              signal.yield()
            }
          }
        }
        schedule(firstExpiry)
        do {
          var last = initial
          for await _ in signals {
            let (next, expiry) = try await self.run(read, token: token)
            schedule(expiry)
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

  /// 登记订阅 `reading` 这些表；`since` 是读到那份时的提交数，其后有过提交（或没读过：nil）就先给一个信号重读。
  /// 第一次读之前什么都可能改动它：没读过的先订阅全部表，读完再收窄。
  private func subscribe(_ signal: AsyncStream<Void>.Continuation, reading tables: Set<Table>, since: Int?) -> UUID {
    let token = UUID()
    subscribers[token] = (tables, signal)
    if since != commits.load(ordering: .acquiring) { signal.yield() }
    return token
  }

  /// 读一次，并把订阅收窄到这次实际读到的表。读与收窄在同一次 actor 执行里，其间没有写入能漏掉。
  /// 也带回结果随时间变的时刻（读里调过 `expire(at:)`）。
  private func run<T>(_ read: (isolated CueStore) throws -> T, token: UUID) throws -> (T, Date?) {
    let (value, reads, expiry) = try tracked(read)
    subscribers[token]?.tables = reads
    return (value, expiry)
  }

  private func tracked<T>(_ read: (isolated CueStore) throws -> T) throws -> (T, Set<Table>, Date?) {
    readExpiry = nil
    let (value, reads) = try db.tracking { try read(self) }
    return (value, reads, readExpiry)
  }

  /// 正在读的结果到 `date` 会随时间变（不是因为库里写了什么）：`observe` 到点再读一次。不在订阅里读时无影响。
  func expire(at date: Date) { readExpiry = min(readExpiry ?? date, date) }

  private func unsubscribe(_ token: UUID) { subscribers[token] = nil }

  // MARK: 内部：事务与通用行读写

  /// 一个写事务；提交后通知订阅者，并把改动的同步记录交给同步订阅者。
  func write<T>(_ body: () throws -> T) throws -> T {
    let (result, changes) = try db.transaction(body)
    let tables = Set(changes.tables.compactMap(Table.init(rawValue:)))
    if !tables.isEmpty {
      commits.add(1, ordering: .releasing)
      ChangeNotification.post(notificationName)
    }
    for (_, subscriber) in subscribers where !subscriber.tables.isDisjoint(with: tables) {
      subscriber.signal.yield()
    }
    if !tables.isDisjoint(with: Table.synced) {
      // 只有让记录变成待推送的提交才算（记账、应用远端版本这类不会）；算不出增量时照算
      let delta = try? pendingSync(in: changes)
      if delta.map({ !$0.saves.isEmpty || !$0.deletes.isEmpty }) ?? true { syncChanged() }
    }
    return result
  }

  private func syncChanged() {
    syncGeneration += 1
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
    try db.query(
      """
      SELECT \(R.selection) FROM \(R.table.rawValue)
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

/// 主线程当场读到的一份（`CueStore.snapshot`）：值，加上从它接着订阅（`observe(from:)`）要的读到的表、当时的提交数与到点重读的时刻。
public struct Snapshot<Value: Sendable>: Sendable {
  public let value: Value
  let tables: Set<Table>
  let version: Int
  let expiry: Date?
}
