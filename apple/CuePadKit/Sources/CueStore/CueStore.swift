import Foundation

/// CuePad 的 SQLite 唯一事实源（系统 SQLite3，App 是唯一写者）。
///
/// 读：`projects()`、`cards(in:)` 等查询；界面用 `observe` 订阅表变更并重读，不在内存里复制状态。
/// 写：每个写方法是一个事务，提交后向订阅者发布一次变更。
public actor CueStore {
  let db: SQLite
  private var subscribers: [UUID: (tables: Set<Table>, signal: AsyncStream<Void>.Continuation)] = [:]

  public init(url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let connection = try SQLite(path: url.path)
    try connection.exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL")
    let applied = try connection.first("PRAGMA user_version") { Int($0.int(0)) } ?? 0
    for (index, script) in Schema.migrations.enumerated() where index >= applied {
      _ = try connection.transaction {
        try connection.exec(script)
        try connection.exec("PRAGMA user_version = \(index + 1)")
      }
    }
    db = connection
  }

  // MARK: 观察

  /// 订阅：先产出一次当前值，之后每当 `tables` 中任一表被提交的写事务改动就重读并产出。
  /// 突发的多次写入会合并为一次重读。`read` 在 store 的隔离域内执行，可直接调用查询方法：
  /// `store.observe([.cards, .projects]) { try $0.cards(in: id) }`
  public nonisolated func observe<T: Sendable>(
    _ tables: Set<Table>, _ read: @escaping @Sendable (isolated CueStore) throws -> T
  ) -> AsyncThrowingStream<T, Error> {
    AsyncThrowingStream { continuation in
      let (signals, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      let task = Task {
        let token = await self.subscribe(tables, signal)
        signal.yield()
        do {
          for await _ in signals { continuation.yield(try await read(self)) }
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

  private func subscribe(_ tables: Set<Table>, _ signal: AsyncStream<Void>.Continuation) -> UUID {
    let token = UUID()
    subscribers[token] = (tables, signal)
    return token
  }

  private func unsubscribe(_ token: UUID) { subscribers[token] = nil }

  // MARK: 内部：事务与通用行读写

  /// 一个写事务；提交后通知订阅者。
  func write<T>(_ body: () throws -> T) throws -> T {
    let (result, changed) = try db.transaction(body)
    let tables = Set(changed.compactMap(Table.init(rawValue:)))
    for (_, subscriber) in subscribers where !subscriber.tables.isDisjoint(with: tables) {
      subscriber.signal.yield()
    }
    return result
  }

  func select<R: Record>(
    _ type: R.Type, where condition: String = "1", _ arguments: [any SQLBindable] = [],
    orderBy: String = "rowid", limit: Int = -1
  ) throws -> [R] {
    try db.query(
      """
      SELECT \(R.columns.joined(separator: ", ")) FROM \(R.table.rawValue)
      WHERE \(condition) ORDER BY \(orderBy) LIMIT \(limit)
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
