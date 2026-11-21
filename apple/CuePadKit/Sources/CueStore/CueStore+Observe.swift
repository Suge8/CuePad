import Foundation

extension CueStore {
  public nonisolated func observe<T: Sendable & Equatable>(
    after initial: T? = nil, _ read: @escaping @Sendable (isolated CueStore) throws -> T
  ) -> AsyncThrowingStream<T, Error> {
    observe(read, reading: Set(Table.allCases), scopes: [:], since: nil, last: initial, expiry: nil)
  }

  public nonisolated func observe<T: Sendable & Equatable>(
    from snapshot: Snapshot<T>, _ read: @escaping @Sendable (isolated CueStore) throws -> T
  ) -> AsyncThrowingStream<T, Error> {
    observe(read, reading: snapshot.tables, scopes: snapshot.scopes, since: snapshot.version, last: snapshot.value, expiry: snapshot.expiry)
  }

  @MainActor
  public func snapshot<T: Sendable>(_ read: @Sendable (isolated CueStore) throws -> T) throws -> Snapshot<T> {
    let since = subscriptions.commits
    let (value, tables, scopes, expiry) = try reader!.assumeIsolated { try $0.tracked(read) }
    return Snapshot(value: value, tables: tables, scopes: scopes, version: since, expiry: expiry)
  }

  private nonisolated func observe<T: Sendable & Equatable>(
    _ read: @escaping @Sendable (isolated CueStore) throws -> T, reading tables: Set<Table>, scopes: [Table: [RowScope]], since: Int?, last initial: T?,
    expiry firstExpiry: Date?
  ) -> AsyncThrowingStream<T, Error> {
    AsyncThrowingStream { continuation in
      let (signals, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      let (subscriptions, rereader) = (self.subscriptions, self.rereader!)
      let task = Task {
        let token = subscriptions.add(signal, reading: tables, scopes: scopes, since: since)
        var timer: Task<Void, Never>?
        defer {
          timer?.cancel()
          subscriptions.remove(token)
        }
        let timing = self.timing
        func schedule(_ expiry: Date?) {
          timer?.cancel()
          timer = expiry.map { due in
            Task {
              guard (try? await timing.sleepUntil(due)) != nil else { return }
              signal.yield()
            }
          }
        }
        schedule(firstExpiry)
        var backoff = Self.firstRetry
        do {
          var last = initial
          for await _ in signals {
            let before = subscriptions.commits
            let (next, reads, scopes, expiry): (T, Set<Table>, [Table: [RowScope]], Date?)
            do {
              (next, reads, scopes, expiry) = try await rereader.tracked(read)
            } catch let error as SQLiteError where error.isTransient {
              try? await timing.sleep(backoff)
              signal.yield()
              backoff = min(backoff * 2, Self.lastRetry)
              continue
            }
            backoff = Self.firstRetry
            subscriptions.settle(token, reading: reads, scopes: scopes, since: before)
            schedule(expiry)
            if next == last { continue }
            last = next
            continuation.yield(next)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in
        signal.finish()
        task.cancel()
      }
    }
  }

  static let firstRetry: Duration = .milliseconds(200)
  static let lastRetry: Duration = .seconds(10)

  private func tracked<T>(_ read: (isolated CueStore) throws -> T) throws -> (T, Set<Table>, [Table: [RowScope]], Date?) {
    try db.exec("BEGIN")
    defer { try? db.exec("COMMIT") }
    readExpiry = nil
    readScopes = [:]
    defer { readScopes = nil }
    let (value, reads) = try db.tracking { try read(self) }
    let scopes = readScopes ?? [:]
    return (value, reads.union(scopes.keys), scopes.filter { !reads.contains($0.key) }, readExpiry)
  }

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

  func expire(at date: Date) { readExpiry = min(readExpiry ?? date, date) }

}

public struct Snapshot<Value: Sendable>: Sendable {
  public let value: Value
  let tables: Set<Table>
  let scopes: [Table: [RowScope]]
  let version: Int
  let expiry: Date?
}

struct RowScope: Sendable {
  let column: String
  let candidates: String
  let arguments: [SQLValue]
  let includes: @Sendable (String) -> Bool
  let rows: Set<Int64>
}
