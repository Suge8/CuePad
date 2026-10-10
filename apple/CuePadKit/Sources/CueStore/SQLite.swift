import Foundation
import SQLite3

/// 绑定到语句的值。只有 CueStore 用到的三种存储类。
package enum SQLValue: Sendable, Equatable {
  case null
  case int(Int64)
  case text(String)
  case blob(Data)
}

protocol SQLBindable: Sendable {
  var sqlValue: SQLValue { get }
}

extension SQLValue: SQLBindable { var sqlValue: SQLValue { self } }

extension String: SQLBindable { var sqlValue: SQLValue { .text(self) } }
extension Int: SQLBindable { var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { var sqlValue: SQLValue { .int(self) } }
extension Data: SQLBindable { var sqlValue: SQLValue { .blob(self) } }
extension Bool: SQLBindable { var sqlValue: SQLValue { .int(self ? 1 : 0) } }
/// 库里 UUID 一律存小写文本（CKRecord 的 recordName 也用这个字符串）。
extension UUID: SQLBindable { var sqlValue: SQLValue { .text(uuidString.lowercased()) } }
extension Date {
  /// 当前时间，精度截到毫秒：返回给调用方的值与落盘后读回的值相等。
  static var stamp: Date { Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000) }
}

/// 时间存 Unix 毫秒整数。
extension Date: SQLBindable {
  var sqlValue: SQLValue { .int(Int64((timeIntervalSince1970 * 1000).rounded())) }
}
extension Optional: SQLBindable where Wrapped: SQLBindable {
  var sqlValue: SQLValue { map(\.sqlValue) ?? .null }
}

struct SQLiteError: Error, CustomStringConvertible {
  let message: String
  let sql: String
  var description: String { "SQLite: \(message) [\(sql)]" }
}

/// 一行结果，按列序号读取。只在 `query` 的回调里有效。
struct Row {
  fileprivate let statement: OpaquePointer

  /// 结果集中某列的序号；没有该列返回 nil。
  func index(of name: String) -> Int32? {
    (0..<sqlite3_column_count(statement)).first { String(cString: sqlite3_column_name(statement, $0)) == name }
  }

  /// 按存储类读出（同步表只有整数与文本两类）。
  func value(_ column: Int32) -> SQLValue {
    switch sqlite3_column_type(statement, column) {
    case SQLITE_NULL: .null
    case SQLITE_INTEGER: .int(int(column))
    case SQLITE_BLOB: .blob(blobOrNil(column) ?? Data())
    default: .text(text(column))
    }
  }

  func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
  func text(_ column: Int32) -> String { String(cString: sqlite3_column_text(statement, column)) }
  func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
  func bool(_ column: Int32) -> Bool { int(column) != 0 }
  func date(_ column: Int32) -> Date { Date(timeIntervalSince1970: Double(int(column)) / 1000) }
  func uuid(_ column: Int32) -> UUID { UUID(uuidString: text(column))! }

  func blobOrNil(_ column: Int32) -> Data? {
    guard !isNull(column) else { return nil }
    let count = Int(sqlite3_column_bytes(statement, column))
    guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
    return Data(bytes: bytes, count: count)
  }

  func textOrNil(_ column: Int32) -> String? { isNull(column) ? nil : text(column) }
  func intOrNil(_ column: Int32) -> Int64? { isNull(column) ? nil : int(column) }
  func dateOrNil(_ column: Int32) -> Date? { isNull(column) ? nil : date(column) }
  func uuidOrNil(_ column: Int32) -> UUID? { isNull(column) ? nil : uuid(column) }
}

/// 一个写事务改动的行：每张表插入或更新过的 rowid，以及删过行的表。由 SQLite 的 update hook 记下（含触发器引起的改动）。
struct Changes {
  var rows: [String: Set<Int64>] = [:]
  var deletedFrom: Set<String> = []

  var tables: Set<String> { deletedFrom.union(rows.keys) }
}

/// 系统 SQLite3 的最薄封装：一个连接、语句、绑定、事务。线程安全由持有它的 actor 保证。
final class SQLite {
  private var handle: OpaquePointer?
  private let changeLog = ChangeLog()
  /// 编译好的语句，按 SQL 文本复用。用时取出、用完放回：同一条 SQL 在回调里被重入时，重入的那次临时编译一条，不共用游标。
  private var statements: [String: OpaquePointer] = [:]
  private static let statementLimit = 128

  init(path: String) throws {
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
      sqlite3_close_v2(handle)
      throw SQLiteError(message: message, sql: "open \(path)")
    }
    sqlite3_busy_timeout(handle, 5000)
    sqlite3_update_hook(
      handle,
      { context, operation, _, table, rowid in
        Unmanaged<ChangeLog>.fromOpaque(context!).takeUnretainedValue().record(operation, String(cString: table!), rowid)
      }, Unmanaged.passUnretained(changeLog).toOpaque())
  }

  deinit {
    for statement in statements.values { sqlite3_finalize(statement) }
    sqlite3_close_v2(handle)
  }

  /// 执行不带参数的一条或多条语句。
  func exec(_ sql: String) throws {
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error(sql) }
  }

  func run(_ sql: String, _ arguments: [any SQLBindable] = []) throws {
    _ = try query(sql, arguments) { _ in () }
  }

  func query<T>(_ sql: String, _ arguments: [any SQLBindable] = [], _ map: (Row) throws -> T) throws -> [T] {
    let statement = try checkOut(sql)
    defer { checkIn(statement, sql) }
    for (index, argument) in arguments.enumerated() {
      let position = Int32(index + 1)
      switch argument.sqlValue {
      case .null: sqlite3_bind_null(statement, position)
      case .int(let value): sqlite3_bind_int64(statement, position, value)
      case .text(let value):
        sqlite3_bind_text(statement, position, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
      case .blob(let value):
        value.withUnsafeBytes {
          _ = sqlite3_bind_blob(statement, position, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
      }
    }
    var rows: [T] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW: rows.append(try map(Row(statement: statement)))
      case SQLITE_DONE: return rows
      default: throw error(sql)
      }
    }
  }

  func first<T>(_ sql: String, _ arguments: [any SQLBindable] = [], _ map: (Row) throws -> T) throws -> T? {
    try query(sql, arguments, map).first
  }

  /// 最近一条语句改动的行数。
  var changes: Int { Int(sqlite3_changes(handle)) }

  /// 提交后返回本事务改动过的行；回滚则丢弃。
  func transaction<T>(_ body: () throws -> T) throws -> (result: T, changes: Changes) {
    try exec("BEGIN IMMEDIATE")
    changeLog.changes = Changes()
    do {
      let result = try body()
      try exec("COMMIT")
      return (result, changeLog.changes)
    } catch {
      try? exec("ROLLBACK")
      throw error
    }
  }

  private func checkOut(_ sql: String) throws -> OpaquePointer {
    if let cached = statements.removeValue(forKey: sql) { return cached }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error(sql) }
    return statement
  }

  private func checkIn(_ statement: OpaquePointer, _ sql: String) {
    sqlite3_reset(statement)
    sqlite3_clear_bindings(statement)
    if statements.count >= Self.statementLimit, let evicted = statements.keys.first {
      sqlite3_finalize(statements.removeValue(forKey: evicted))
    }
    if let existing = statements.updateValue(statement, forKey: sql) { sqlite3_finalize(existing) }
  }

  private func error(_ sql: String) -> SQLiteError {
    SQLiteError(message: String(cString: sqlite3_errmsg(handle)), sql: sql)
  }
}

/// 更新钩子只在持有连接的 actor 上、语句执行期间被调用，无并发访问。
private final class ChangeLog: @unchecked Sendable {
  var changes = Changes()

  func record(_ operation: Int32, _ table: String, _ rowid: Int64) {
    if operation == SQLITE_DELETE {
      changes.deletedFrom.insert(table)
    } else {
      changes.rows[table, default: []].insert(rowid)
    }
  }
}
