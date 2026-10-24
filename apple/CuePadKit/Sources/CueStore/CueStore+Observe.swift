import Foundation
import Synchronization

extension CueStore {
  /// 订阅：先产出一次当前值，之后每当 `read` 读到的表被提交的写事务改动就重读并产出。依赖的表由读取本身决定
  /// （每次读完按它实际读到的表更新，随数据走不同分支也对），调用处不另声明；这是订阅的唯一写法——
  /// 只要"变了就叫我"的也读一个会跟着变的值（计数、版本、列表），不单独订阅表。
  /// 结果随时间变的（读里登记了 `expire(at:)`，如 Cue 那台 Mac 算不算在线）到点也重读，不轮询。
  /// 突发的多次写入会合并为一次重读。`read` 在 store 的隔离域内执行，可直接调用查询方法：
  /// `store.observe { try $0.cards(in: id) }`
  /// 订阅以表为粒度：别的行改动同一张表也会重读，但结果和上一次一样就不产出——比较只在读取的这一侧做一次，
  /// 不把没变的数据送到主线程、也不让界面白白重算。`initial` 是调用方手里已有的值，当作"上一次"：重新订阅后第一份没变也不产出。
  /// 读里按行收窄过的表（`narrow`）例外：只改动那张表别的行的写入不叫醒它。
  public nonisolated func observe<T: Sendable & Equatable>(
    after initial: T? = nil, _ read: @escaping @Sendable (isolated CueStore) throws -> T
  ) -> AsyncThrowingStream<T, Error> {
    observe(read, reading: Set(Table.allCases), scopes: [:], since: nil, last: initial, expiry: nil)
  }

  /// 从主线程当场读到的那份（`snapshot`）接着订阅：不重读，之后的变化照 `observe`；快照之后已有写入的，马上重读一次。
  public nonisolated func observe<T: Sendable & Equatable>(
    from snapshot: Snapshot<T>, _ read: @escaping @Sendable (isolated CueStore) throws -> T
  ) -> AsyncThrowingStream<T, Error> {
    observe(read, reading: snapshot.tables, scopes: snapshot.scopes, since: snapshot.version, last: snapshot.value, expiry: snapshot.expiry)
  }

  /// 主线程上当场读一次（只读连接，不等队列）：界面第一帧要的值，读到的表与时刻一并记下，交给 `observe(from:)` 接着订阅。
  @MainActor
  public func snapshot<T: Sendable>(_ read: @Sendable (isolated CueStore) throws -> T) throws -> Snapshot<T> {
    // 先取提交数再读：其间有提交的，接着订阅时多重读一次，不会漏
    let since = commits.load(ordering: .acquiring)
    let (value, tables, scopes, expiry) = try (reader ?? self).assumeIsolated { try $0.tracked(read) }
    return Snapshot(value: value, tables: tables, scopes: scopes, version: since, expiry: expiry)
  }

  /// 订阅 `tables`（`since` 见 `subscribe`），每个信号重读一次；`last` 是第一次比较的"上一次"，`expiry` 是它到点重读的时刻。
  private nonisolated func observe<T: Sendable & Equatable>(
    _ read: @escaping @Sendable (isolated CueStore) throws -> T, reading tables: Set<Table>, scopes: [Table: [RowScope]], since: Int?, last initial: T?,
    expiry firstExpiry: Date?
  ) -> AsyncThrowingStream<T, Error> {
    AsyncThrowingStream { continuation in
      let (signals, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      let task = Task {
        let token = await self.subscribe(signal, reading: tables, scopes: scopes, since: since)
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
  private func subscribe(_ signal: AsyncStream<Void>.Continuation, reading tables: Set<Table>, scopes: [Table: [RowScope]], since: Int?) -> UUID {
    let token = UUID()
    subscribers[token] = (tables, scopes, signal)
    if since != commits.load(ordering: .acquiring) { signal.yield() }
    return token
  }

  /// 读一次，并把订阅收窄到这次实际读到的表。读与收窄在同一次 actor 执行里，其间没有写入能漏掉。
  /// 也带回结果随时间变的时刻（读里调过 `expire(at:)`）。
  private func run<T>(_ read: (isolated CueStore) throws -> T, token: UUID) throws -> (T, Date?) {
    let (value, reads, scopes, expiry) = try tracked(read)
    subscribers[token]?.tables = reads
    subscribers[token]?.scopes = scopes
    return (value, expiry)
  }

  /// 读一次，带回读到的表、其中按行收窄的（同一次读里又整表读过的不算收窄）与结果随时间变的时刻。
  private func tracked<T>(_ read: (isolated CueStore) throws -> T) throws -> (T, Set<Table>, [Table: [RowScope]], Date?) {
    readExpiry = nil
    readScopes = [:]
    defer { readScopes = nil }
    let (value, reads) = try db.tracking { try read(self) }
    let scopes = readScopes ?? [:]
    return (value, reads.union(scopes.keys), scopes.filter { !reads.contains($0.key) }, readExpiry)
  }

  /// 这次读只依赖 `table` 里 `column` 满足 `includes` 的行：先按 SQL 条件 `candidates`（绑定 `arguments`；可走索引，要排除这一列为 NULL 的行）取候选行再逐行精判，
  /// 把这些行（rowid）交给 `body`，并登记给订阅——之后的写入只改动这张表的别的行（改动前不在其中、改动后也不满足）时不叫醒它。`body` 里对这张表的读不算整表依赖，
  /// 要只读这些行（如 `rowid IN`）；同一次读里收窄几次各记一份，任一命中就叫醒；别处再整表读这张表的，收窄作废。不在订阅里读时只取行、不登记。
  /// 会话状态每变一次，项目引导这类只看几行的订阅就不必重读。
  @discardableResult
  func narrow<T>(
    _ table: Table, column: String, candidates: String, arguments: [any SQLBindable] = [], to includes: @escaping @Sendable (String) -> Bool,
    _ body: (Set<Int64>) throws -> T
  ) throws -> T {
    try db.untracked(table) {
      let rows = Set(try db.query("SELECT rowid, \(column) FROM \(table.rawValue) WHERE \(candidates)", arguments) { ($0.int(0), $0.text(1)) }
        .filter { includes($0.1) }.map(\.0))
      readScopes?[table, default: []].append(
        RowScope(column: column, candidates: candidates, arguments: arguments.map(\.sqlValue), includes: includes, rows: rows))
      return try body(rows)
    }
  }

  /// 这次提交会不会改变订阅者读到的：碰了它整表读的表，或碰了它收窄的表里任一份依赖的行（原来在其中的，或改动后满足条件的）。判断不出来按会。
  func touches(_ tables: Set<Table>, _ changes: Changes, reading: Set<Table>, scopes: [Table: [RowScope]]) -> Bool {
    let touched = reading.intersection(tables)
    if touched.contains(where: { scopes[$0] == nil }) { return true }
    return touched.contains { table in scopes[table]!.contains { touches(table, changes, $0) } }
  }

  private func touches(_ table: Table, _ changes: Changes, _ scope: RowScope) -> Bool {
    let changed = changes.rows[table.rawValue] ?? []
    if !scope.rows.isDisjoint(with: changed) || !scope.rows.isDisjoint(with: changes.deleted[table.rawValue] ?? []) { return true }
    guard !changed.isEmpty else { return false }
    let values = try? db.query(
      "SELECT \(scope.column) FROM \(table.rawValue) WHERE rowid IN (SELECT value FROM json_each(?)) AND (\(scope.candidates))",
      [JSONColumn.encode(changed.sorted())] + scope.arguments) { $0.text(0) }
    return values.map { $0.contains(where: scope.includes) } ?? true
  }

  /// 正在读的结果到 `date` 会随时间变（不是因为库里写了什么）：`observe` 到点再读一次。不在订阅里读时无影响。
  func expire(at date: Date) { readExpiry = min(readExpiry ?? date, date) }

  private func unsubscribe(_ token: UUID) { subscribers[token] = nil }
}

/// 主线程当场读到的一份（`CueStore.snapshot`）：值，加上从它接着订阅（`observe(from:)`）要的读到的表、当时的提交数与到点重读的时刻。
public struct Snapshot<Value: Sendable>: Sendable {
  public let value: Value
  let tables: Set<Table>
  let scopes: [Table: [RowScope]]
  let version: Int
  let expiry: Date?
}

/// 一次读依赖的一张表里的那些行（`CueStore.narrow`）：读时满足条件的行，与判断改动后的行满不满足用的列、候选条件（连同绑定的参数）与精判。
struct RowScope: Sendable {
  let column: String
  let candidates: String
  let arguments: [SQLValue]
  let includes: @Sendable (String) -> Bool
  let rows: Set<Int64>
}
