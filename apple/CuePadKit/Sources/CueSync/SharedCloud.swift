import CloudKit
import CueStore
import Foundation
import SQLite3

/// 同步测量的模拟云（`sync-bench.py` 默认）：同一台机器上几个进程共用一个 SQLite 文件当同步区，不连 iCloud、不吃设备限流。
/// 同步代码照真的跑（`CloudSync` 只换掉网络那一头，同 `SimulatedCloud`），每个请求按延迟模型睡一段（`Latency`，脚本写在目录里的 latency.json，
/// 数值与出处只在脚本头注释；没有这个文件就不睡）：
/// 上传先睡六成再落盘、再睡剩下的（服务器收下在回包之前），拉取先睡六成再读。令牌是写入序号，一页至多 `page` 条（`moreComing`）。
/// 不模拟：改记录冲突（serverRecordChanged）、cloudd 的排队。限流只在脚本要时注入（`admit`）。门铃的密钥是这次运行的（文件里一份），房间不与别的运行重合。
/// 每个请求（认账号除外）记进 requests 表：时刻、进程、种类、结果、回给它的 Retry-After，脚本按它数各进程发了几次、守没守 Retry-After；
/// 拉取与上传另记模型抽到的用时（drawn）与回到调用方的时刻（done），两者之差是落盘与调用方那头没及时接回来的部分。
struct SharedCloud: SyncCloud {
  /// 每种请求的用时分布：对数正态，按中位与 p95 定。
  struct Latency: Decodable, Sendable {
    var upload: [Double]
    var fetch: [Double]
    var records: [Double]
    var other: [Double]

    static let none = Latency(upload: [0, 0], fetch: [0, 0], records: [0, 0], other: [0, 0])

    /// 一次请求的总用时（秒）。
    static func draw(_ spec: [Double]) -> Double {
      guard spec.count == 2, spec[0] > 0 else { return 0 }
      let sigma = log(max(spec[1], spec[0]) / spec[0]) / 1.645
      // Box–Muller：一个标准正态
      let normal = sqrt(-2 * log(Double.random(in: Double.ulpOfOne..<1))) * cos(2 * .pi * Double.random(in: 0..<1))
      return spec[0] * exp(sigma * normal)
    }
  }

  let path: String
  let latency: Latency
  private let throttleFile: URL

  /// 脚本写的限流窗口（throttle.json）：到 `until`（墙钟秒）之前到了服务器的请求回 429，带 `retryAfter`。
  private struct Throttle: Decodable {
    var until: Double
    var retryAfter: Double
  }
  private static let page = 200
  private static let zoneID = CloudSync.zoneID

  init(directory: URL) {
    path = directory.appending(path: "cloud.sqlite").path()
    throttleFile = directory.appending(path: "throttle.json")
    latency = (try? JSONDecoder().decode(Latency.self, from: Data(contentsOf: directory.appending(path: "latency.json")))) ?? .none
  }

  func accountStatus() async throws -> CKAccountStatus { await wait(latency.other); return .available }
  func accountName() async throws -> String { await wait(latency.other); return "sync-bench" }

  func relaySecret() async throws -> Data {
    try admit("other")
    await wait(latency.other)
    return try database { db in
      if let secret = try db.blob("SELECT value FROM meta WHERE key = 'relaySecret'") { return secret }
      let secret = Data((0..<RelaySecret.length).map { _ in UInt8.random(in: 0...255) })
      try db.run("INSERT OR IGNORE INTO meta (key, value) VALUES ('relaySecret', ?)", secret)
      return try db.blob("SELECT value FROM meta WHERE key = 'relaySecret'") ?? secret
    }
  }

  func changes(since token: Data?, keys: [String]?) async throws -> ZoneChangeBatch {
    let total = Latency.draw(latency.fetch)
    let row = try admit("fetch", drawn: total)
    try? await Task.sleep(for: .seconds(total * 0.6))
    let after = token.flatMap { Int64(String(decoding: $0, as: UTF8.self)) } ?? 0
    let batch = try database { db in
      let rows = try db.rows("SELECT seq, name, type, data FROM records WHERE seq > ? ORDER BY seq LIMIT \(Self.page + 1)", after)
      let taken = rows.prefix(Self.page)
      var batch = ZoneChangeBatch(modifications: [], deletions: [], token: Data(String(taken.last?.seq ?? after).utf8), moreComing: rows.count > Self.page)
      for row in taken {
        if let data = row.data {
          batch.modifications.append(try Self.record(data))
        } else {
          batch.deletions.append((CKRecord.ID(recordName: row.name, zoneID: Self.zoneID), row.type))
        }
      }
      return batch
    }
    try? await Task.sleep(for: .seconds(total * 0.4))
    finish(row)
    return batch
  }

  func records(_ ids: [CKRecord.ID]) async throws -> [CKRecord] {
    try admit("records")
    await wait(latency.records)
    return try database { db in
      try ids.compactMap { id in try db.blob("SELECT data FROM records WHERE name = ?", id.recordName).map(Self.record) }
    }
  }

  func upload(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> SentRecords {
    let total = Latency.draw(latency.upload)
    let row = try admit("upload", drawn: total)
    try? await Task.sleep(for: .seconds(total * 0.6))
    try database { db in
      try db.run("BEGIN IMMEDIATE")
      do {
        for record in saving {
          let data = try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
          try db.run("INSERT OR REPLACE INTO records (name, type, data, seq) VALUES (?, ?, ?, (SELECT IFNULL(MAX(seq), 0) + 1 FROM records))",
                     record.recordID.recordName, record.recordType, data)
        }
        for id in deleting {
          try db.run("UPDATE records SET data = NULL, seq = (SELECT IFNULL(MAX(seq), 0) + 1 FROM records) WHERE name = ?", id.recordName)
        }
        try db.run("COMMIT")
      } catch {
        try? db.run("ROLLBACK")
        throw error
      }
    }
    try? await Task.sleep(for: .seconds(total * 0.4))
    finish(row)
    return SentRecords(saved: saving, deleted: deleting)
  }

  func saveZone() async throws {
    try admit("other")
    await wait(latency.other)
  }
  func subscriptions() async throws -> [CKSubscription.ID: CKSubscription] { [:] }
  func save(_ subscription: CKSubscription) async throws {}
  func delete(_ id: CKSubscription.ID) async throws {}

  /// 记下这个请求，限流窗口里按 CloudKit 的设备限流回：到了服务器的回 429、带 `retryAfter`，并记下这台在那之前不再收（几个进程共用一份，同设备限流）；
  /// 那之前来的当场回"被上一次 429 限着"（结果记 early），Retry-After 是剩下的秒数。窗口过了照常。
  @discardableResult
  private func admit(_ kind: String, drawn: Double? = nil) throws -> Int64 {
    let now = Date.now.timeIntervalSince1970
    let window = try? JSONDecoder().decode(Throttle.self, from: Data(contentsOf: throttleFile))
    let (row, refused): (Int64, Double?) = try database { db in
      try db.run("BEGIN IMMEDIATE")
      do {
        let blocked = try db.double("SELECT value FROM meta WHERE key = 'blockedUntil'") ?? 0
        var result = "ok", wait: Double?
        if now < blocked {
          (result, wait) = ("early", blocked - now)
        } else if let window, now < window.until {
          (result, wait) = ("429", window.retryAfter)
          try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('blockedUntil', ?)", now + window.retryAfter)
        }
        try db.run("INSERT INTO requests (t, pid, kind, result, wait, drawn) VALUES (?, ?, ?, ?, ?, ?)", now, Int64(getpid()), kind, result, wait as Any, drawn as Any)
        let row = db.lastRow
        try db.run("COMMIT")
        return (row, wait)
      } catch {
        try? db.run("ROLLBACK")
        throw error
      }
    }
    if let refused { throw CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: refused]) }
    return row
  }

  private func finish(_ row: Int64) {
    try? database { try $0.run("UPDATE requests SET done = ? WHERE rowid = ?", Date.now.timeIntervalSince1970, row) }
  }

  private func wait(_ spec: [Double]) async { try? await Task.sleep(for: .seconds(Latency.draw(spec))) }

  private static func record(_ data: Data) throws -> CKRecord {
    guard let record = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data) else { throw CKError(.internalError) }
    return record
  }

  /// 每次请求开一次连接（请求本来就隔着上百毫秒，几个进程各开各的，锁交给 SQLite 的 WAL 与 busy_timeout）。
  private func database<T>(_ body: (Connection) throws -> T) throws -> T {
    let db = try Connection(path)
    defer { db.close() }
    return try body(db)
  }

  private final class Connection {
    private var handle: OpaquePointer?

    init(_ path: String) throws {
      guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { throw failure }
      sqlite3_busy_timeout(handle, 10_000)
      try exec("""
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS records (name TEXT PRIMARY KEY, type TEXT NOT NULL, data BLOB, seq INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS records_seq ON records(seq);
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value BLOB);
        CREATE TABLE IF NOT EXISTS requests (t REAL NOT NULL, pid INTEGER NOT NULL, kind TEXT NOT NULL, result TEXT NOT NULL, wait REAL, drawn REAL, done REAL);
        """)
    }

    func close() { sqlite3_close(handle) }

    var lastRow: Int64 { sqlite3_last_insert_rowid(handle) }

    private var failure: CKError {
      CKError(.internalError, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
    }

    private func exec(_ sql: String) throws {
      guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure }
    }

    func run(_ sql: String, _ values: Any...) throws {
      try query(sql, values) { _ in }
    }

    func blob(_ sql: String, _ values: Any...) throws -> Data? {
      var found: Data?
      try query(sql, values) { statement in found = Self.data(statement, 0) }
      return found
    }

    func double(_ sql: String, _ values: Any...) throws -> Double? {
      var found: Double?
      try query(sql, values) { statement in found = sqlite3_column_double(statement, 0) }
      return found
    }

    func rows(_ sql: String, _ values: Any...) throws -> [(seq: Int64, name: String, type: String, data: Data?)] {
      var rows: [(seq: Int64, name: String, type: String, data: Data?)] = []
      try query(sql, values) { statement in
        rows.append((sqlite3_column_int64(statement, 0), String(cString: sqlite3_column_text(statement, 1)),
                     String(cString: sqlite3_column_text(statement, 2)), Self.data(statement, 3)))
      }
      return rows
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func query(_ sql: String, _ values: [Any], _ row: (OpaquePointer) -> Void) throws {
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure }
      defer { sqlite3_finalize(statement) }
      for (index, value) in values.enumerated() {
        let at = Int32(index + 1)
        switch value {
        case let text as String: sqlite3_bind_text(statement, at, text, -1, Self.transient)
        case let number as Int64: sqlite3_bind_int64(statement, at, number)
        case let number as Double: sqlite3_bind_double(statement, at, number)
        case let data as Data: _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, at, $0.baseAddress, Int32(data.count), Self.transient) }
        default: sqlite3_bind_null(statement, at)
        }
      }
      while true {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: row(statement)
        case SQLITE_DONE: return
        default: throw failure
        }
      }
    }

    private static func data(_ statement: OpaquePointer, _ column: Int32) -> Data? {
      guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
      let count = Int(sqlite3_column_bytes(statement, column))
      guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
      return Data(bytes: bytes, count: count)
    }
  }
}
