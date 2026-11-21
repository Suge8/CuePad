import Foundation
import OSLog
import SQLite3

package enum SQLValue: Codable, Sendable, Equatable {
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
extension UUID: SQLBindable { var sqlValue: SQLValue { .text(uuidString.lowercased()) } }
extension Date {
  static var stamp: Date { Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000) }
}

extension Date: SQLBindable {
  var sqlValue: SQLValue { .int(stored) }

  public var stored: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}
extension Optional: SQLBindable where Wrapped: SQLBindable {
  var sqlValue: SQLValue { map(\.sqlValue) ?? .null }
}

func sqlList<Value: RawRepresentable>(_ values: some Sequence<Value>) -> String where Value.RawValue == String {
  values.map { "'\($0.rawValue)'" }.joined(separator: ", ")
}

struct SQLiteError: LocalizedError, CustomStringConvertible {
  let message: String
  let sql: String
  var code: Int32 = SQLITE_ERROR
  var isTransient: Bool { [SQLITE_FULL, SQLITE_IOERR, SQLITE_BUSY, SQLITE_LOCKED, SQLITE_NOMEM, SQLITE_CANTOPEN].contains(code & 0xff) }
  var description: String { "SQLite: \(message) [\(sql)]" }
  var errorDescription: String? { String(localized: "资料库读写出错：\(message)") }
}

struct Row {
  fileprivate let statement: OpaquePointer

  func index(of name: String) -> Int32? {
    (0..<sqlite3_column_count(statement)).first { String(cString: sqlite3_column_name(statement, $0)) == name }
  }

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
  var deleted: [String: Set<Int64>] = [:]

  var deletedFrom: Set<String> { Set(deleted.keys) }
  var tables: Set<String> { deletedFrom.union(rows.keys) }
}

final class SQLite {
  private var handle: OpaquePointer?
  private let changeLog = ChangeLog()
  private let compiling = Compiling()
  private var statements: [String: Compiled] = [:]
  private static let statementLimit = 128
  private static let log = Logger(subsystem: AppIdentity.id, category: "sqlite")
  private var tracked: Set<Table>?

  private struct Compiled {
    var statement: OpaquePointer
    var reads: Set<Table>
  }

  init(path: String) throws {
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
      sqlite3_close_v2(handle)
      throw SQLiteError(message: message, sql: "open \(path)")
    }
    sqlite3_busy_timeout(handle, 5000)
    // 授权回调在编译每条语句时（含 exec）被问：记下 `checkOut` 编译的语句读哪些表；删我们的表的行一律逐行删。
    // 不带 WHERE 的整表删除本会走截断优化，那样更新钩子不触发，这次提交就记不到这张表，读它的订阅不被叫醒（清掉同步数据时实测）。
    // 对 DELETE 返回 SQLITE_IGNORE 只关掉截断优化、照删（SQLite 的 DELETE 文档）；但 DROP TABLE、DROP TRIGGER 也会问一次 DELETE，
    // 那时忽略就把整条 DROP 跳过了（升级结构时实测），所以同一次编译里先问过 DROP 的不忽略。
    sqlite3_set_authorizer(
      handle,
      { context, action, table, _, _, _ in
        let compiling = Unmanaged<Compiling>.fromOpaque(context!).takeUnretainedValue()
        switch action {
        case SQLITE_DROP_TABLE, SQLITE_DROP_TEMP_TABLE, SQLITE_DROP_TRIGGER, SQLITE_DROP_TEMP_TRIGGER, SQLITE_DROP_INDEX, SQLITE_DROP_TEMP_INDEX,
          SQLITE_DROP_VIEW, SQLITE_DROP_TEMP_VIEW, SQLITE_DROP_VTABLE:
          compiling.drops = true
        case SQLITE_DELETE, SQLITE_READ:
          guard let table, let known = Table(rawValue: String(cString: table)) else { break }
          if action == SQLITE_READ { compiling.reads?.insert(known) } else if !compiling.drops { return SQLITE_IGNORE }
        default: break
        }
        return SQLITE_OK
      }, Unmanaged.passUnretained(compiling).toOpaque())
    sqlite3_update_hook(
      handle,
      { context, operation, _, table, rowid in
        Unmanaged<ChangeLog>.fromOpaque(context!).takeUnretainedValue().record(operation, String(cString: table!), rowid)
      }, Unmanaged.passUnretained(changeLog).toOpaque())
  }

  deinit {
    for compiled in statements.values { sqlite3_finalize(compiled.statement) }
    sqlite3_close_v2(handle)
  }

  func exec(_ sql: String) throws {
    compiling.drops = false
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error(sql) }
  }

  func run(_ sql: String, _ arguments: [any SQLBindable] = []) throws {
    _ = try query(sql, arguments) { _ in () }
  }

  func query<T>(_ sql: String, _ arguments: [any SQLBindable] = [], _ map: (Row) throws -> T) throws -> [T] {
    let compiled = try checkOut(sql)
    let statement = compiled.statement
    tracked?.formUnion(compiled.reads)
    defer { checkIn(compiled, sql) }
    for (index, argument) in arguments.enumerated() {
      let position = Int32(index + 1)
      switch argument.sqlValue {
      case .null: sqlite3_bind_null(statement, position)
      case .int(let value): sqlite3_bind_int64(statement, position, value)
      case .text(let value):
        sqlite3_bind_text(statement, position, value, -1, SQLITE_TRANSIENT)
      case .blob(let value):
        value.withUnsafeBytes {
          _ = sqlite3_bind_blob(statement, position, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT)
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

  var changes: Int { Int(sqlite3_changes(handle)) }

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

  private func checkOut(_ sql: String) throws -> Compiled {
    if let cached = statements.removeValue(forKey: sql) { return cached }
    compiling.reads = []
    compiling.drops = false
    defer { compiling.reads = nil }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error(sql) }
    return Compiled(statement: statement, reads: compiling.reads ?? [])
  }

  private func checkIn(_ compiled: Compiled, _ sql: String) {
    sqlite3_reset(compiled.statement)
    sqlite3_clear_bindings(compiled.statement)
    if statements.count >= Self.statementLimit, let evicted = statements.keys.first {
      sqlite3_finalize(statements.removeValue(forKey: evicted)?.statement)
    }
    if let existing = statements.updateValue(compiled, forKey: sql) { sqlite3_finalize(existing.statement) }
  }

  func tracking<T>(_ body: () throws -> T) rethrows -> (value: T, reads: Set<Table>) {
    tracked = []
    defer { tracked = nil }
    let value = try body()
    return (value, tracked ?? [])
  }

  func untracked<T>(_ table: Table, _ body: () throws -> T) rethrows -> T {
    let had = tracked?.contains(table) ?? true
    defer { if !had { tracked?.remove(table) } }
    return try body()
  }

  private func error(_ sql: String) -> any Error {
    if sqlite3_errcode(handle) & 0xff == SQLITE_READONLY { return CueStoreError.readOnlyLibrary }
    let error = SQLiteError(message: String(cString: sqlite3_errmsg(handle)), sql: sql, code: sqlite3_extended_errcode(handle))
    Self.log.error("\(error.description, privacy: .public)")
    return error
  }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class Compiling: @unchecked Sendable {
  var reads: Set<Table>?
  var drops = false
}

private final class ChangeLog: @unchecked Sendable {
  var changes = Changes()

  func record(_ operation: Int32, _ table: String, _ rowid: Int64) {
    if operation == SQLITE_DELETE {
      changes.deleted[table, default: []].insert(rowid)
    } else {
      changes.rows[table, default: []].insert(rowid)
    }
  }
}
