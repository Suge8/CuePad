import Foundation
import OSLog
import SQLite3

/// 绑定到语句的值，即 SQLite 的四种存储类。
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
/// 库里 UUID 一律存小写文本（CKRecord 的 recordName 也用这个字符串）。
extension UUID: SQLBindable { var sqlValue: SQLValue { .text(uuidString.lowercased()) } }
extension Date {
  /// 当前时间，精度截到毫秒：返回给调用方的值与落盘后读回的值相等。
  static var stamp: Date { Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000) }
}

/// 时间存 Unix 毫秒整数。
extension Date: SQLBindable {
  var sqlValue: SQLValue { .int(stored) }

  /// 库里存的样子（毫秒）：同一时刻经库、经 JSON、或从桥上直接来的值，按它比是不是同一刻。
  public var stored: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}
extension Optional: SQLBindable where Wrapped: SQLBindable {
  var sqlValue: SQLValue { map(\.sqlValue) ?? .null }
}

/// SQL `IN (…)` 里的字面量列表：枚举的原始值（只来自代码里的枚举，不来自输入）。
func sqlList<Value: RawRepresentable>(_ values: some Sequence<Value>) -> String where Value.RawValue == String {
  values.map { "'\($0.rawValue)'" }.joined(separator: ", ")
}

/// 提示里只给 SQLite 的原因；连同出错的语句记进日志（`SQLite.error`）。
struct SQLiteError: LocalizedError, CustomStringConvertible {
  let message: String
  let sql: String
  var description: String { "SQLite: \(message) [\(sql)]" }
  var errorDescription: String? { String(localized: "资料库读写出错：\(message)") }
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
  /// 插入或改动的行（rowid），按表。
  var rows: [String: Set<Int64>] = [:]
  /// 删掉的行（rowid），按表。
  var deleted: [String: Set<Int64>] = [:]

  var deletedFrom: Set<String> { Set(deleted.keys) }
  var tables: Set<String> { deletedFrom.union(rows.keys) }
}

/// 系统 SQLite3 的最薄封装：一个连接、语句、绑定、事务。线程安全由持有它的 actor 保证。
final class SQLite {
  private var handle: OpaquePointer?
  private let changeLog = ChangeLog()
  /// 编译好的语句，按 SQL 文本复用，连同它读到的表。用时取出、用完放回：同一条 SQL 在回调里被重入时，重入的那次临时编译一条，不共用游标。
  private var statements: [String: Compiled] = [:]
  private static let statementLimit = 128
  private static let log = Logger(subsystem: AppIdentity.id, category: "sqlite")
  /// `tracking` 期间读到的表。
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
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error(sql) }
  }

  /// 定义一个参数的 BLOB → BLOB SQL 函数（NULL 原样返回），给按行改写整张表的升级步骤用：一条 INSERT … SELECT 做完，行不进出 Swift。
  func define(_ name: String, _ transform: @escaping (UnsafeRawBufferPointer) -> [UInt8]) throws {
    let status = sqlite3_create_function_v2(
      handle, name, 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, Unmanaged.passRetained(BlobFunction(transform)).toOpaque(),
      { context, _, values in
        guard let value = values?[0], sqlite3_value_type(value) != SQLITE_NULL else { return sqlite3_result_null(context) }
        let blob = sqlite3_value_blob(value)
        let result = Unmanaged<BlobFunction>.fromOpaque(sqlite3_user_data(context)!).takeUnretainedValue()
          .transform(UnsafeRawBufferPointer(start: blob, count: Int(sqlite3_value_bytes(value))))
        result.withUnsafeBytes { sqlite3_result_blob(context, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
      }, nil, nil, { Unmanaged<BlobFunction>.fromOpaque($0!).release() })
    guard status == SQLITE_OK else { throw error("define \(name)") }
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

  /// 取出缓存的语句；没有就编译，同时由授权回调记下它读哪些表（只在编译时回调，缓存命中不再付出）。
  private func checkOut(_ sql: String) throws -> Compiled {
    if let cached = statements.removeValue(forKey: sql) { return cached }
    let log = ReadLog()
    sqlite3_set_authorizer(
      handle,
      { context, action, table, _, _, _ in
        if action == SQLITE_READ, let table, let known = Table(rawValue: String(cString: table)) {
          Unmanaged<ReadLog>.fromOpaque(context!).takeUnretainedValue().tables.insert(known)
        }
        return SQLITE_OK
      }, Unmanaged.passUnretained(log).toOpaque())
    defer { sqlite3_set_authorizer(handle, nil, nil) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error(sql) }
    return Compiled(statement: statement, reads: log.tables)
  }

  private func checkIn(_ compiled: Compiled, _ sql: String) {
    sqlite3_reset(compiled.statement)
    sqlite3_clear_bindings(compiled.statement)
    if statements.count >= Self.statementLimit, let evicted = statements.keys.first {
      sqlite3_finalize(statements.removeValue(forKey: evicted)?.statement)
    }
    if let existing = statements.updateValue(compiled, forKey: sql) { sqlite3_finalize(existing.statement) }
  }

  /// 执行 `body`，并给出它经 `query` 读到的表（含子查询、连接）。读一次是在持有连接的 actor 上同步完成的，期间没有别的写入。
  func tracking<T>(_ body: () throws -> T) rethrows -> (value: T, reads: Set<Table>) {
    tracked = []
    defer { tracked = nil }
    let value = try body()
    return (value, tracked ?? [])
  }

  /// 执行 `body`，其间读到 `table` 不记进正在进行的 `tracking`：调用方自己按行登记依赖（`CueStore.narrow`）。
  /// 这之前或之后的读也碰了 `table` 的，照常记下。
  func untracked<T>(_ table: Table, _ body: () throws -> T) rethrows -> T {
    let had = tracked?.contains(table) ?? true
    defer { if !had { tracked?.remove(table) } }
    return try body()
  }

  private func error(_ sql: String) -> any Error {
    if sqlite3_errcode(handle) & 0xff == SQLITE_READONLY { return CueStoreError.readOnlyLibrary }
    let error = SQLiteError(message: String(cString: sqlite3_errmsg(handle)), sql: sql)
    Self.log.error("\(error.description, privacy: .public)")
    return error
  }
}

/// 注册成 SQL 函数的闭包：经 C 回调的 user data 带进去。
private final class BlobFunction {
  let transform: (UnsafeRawBufferPointer) -> [UInt8]
  init(_ transform: @escaping (UnsafeRawBufferPointer) -> [UInt8]) { self.transform = transform }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class ReadLog: @unchecked Sendable {
  var tables: Set<Table> = []
}

/// 更新钩子只在持有连接的 actor 上、语句执行期间被调用，无并发访问。
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
