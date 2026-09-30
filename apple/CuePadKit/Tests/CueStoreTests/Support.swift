import CueStore
import CoreGraphics
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers
import Testing

/// 临时目录里的真实库文件；释放时清理。
final class Fixture: @unchecked Sendable {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "cuepad-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
  var url: URL { directory.appending(path: "cuepad.db") }
  let store: CueStore

  init() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    store = try CueStore(url: directory.appending(path: "cuepad.db"))
  }

  deinit { try? FileManager.default.removeItem(at: directory) }
}

/// 用独立的 sqlite3 连接直接读写库文件：构造并发场景、检查落盘格式与旧库 fixture。
struct RawDB {
  let path: String

  init(_ url: URL) { path = url.path }

  func exec(_ sql: String) throws {
    var handle: OpaquePointer?
    defer { sqlite3_close(handle) }
    guard sqlite3_open(path, &handle) == SQLITE_OK else { throw RawError(message: "open") }
    sqlite3_busy_timeout(handle, 5000)
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
      throw RawError(message: String(cString: sqlite3_errmsg(handle)))
    }
  }

  /// 每行每列按文本读出（NULL 为 "NULL"）。
  func rows(_ sql: String) throws -> [[String]] {
    var handle: OpaquePointer?
    defer { sqlite3_close(handle) }
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      throw RawError(message: "open")
    }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
      throw RawError(message: String(cString: sqlite3_errmsg(handle)))
    }
    defer { sqlite3_finalize(statement) }
    var result: [[String]] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      result.append(
        (0..<sqlite3_column_count(statement)).map { column in
          sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "NULL"
        })
    }
    return result
  }

  func count(_ table: String) throws -> Int { Int(try rows("SELECT count(*) FROM \(table)")[0][0])! }
}

struct RawError: Error { let message: String }

func bodies(_ cards: [Card]) -> [String] { cards.map(\.body) }

func sameInstant(_ a: Date?, _ b: Date, sourceLocation: SourceLocation = #_sourceLocation) {
  guard let a else {
    Issue.record("date is nil", sourceLocation: sourceLocation)
    return
  }
  #expect(abs(a.timeIntervalSince(b)) < 0.002, sourceLocation: sourceLocation)
}

/// 纯色 PNG；`shade` 不同则字节不同。
func pngData(width: Int, height: Int, shade: CGFloat = 0.5) -> Data {
  let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(red: shade, green: 0.2, blue: 0.8, alpha: 1)
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  let data = NSMutableData()
  let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, context.makeImage()!, nil)
  CGImageDestinationFinalize(destination)
  return data as Data
}

/// 手动推进的时钟：`now` 只在 `advance` 时前进，`sleep` 挂起到 `advance` 越过截止时间。
final class ManualTiming: @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date
  private var sleepers: [UUID: (deadline: Date, continuation: CheckedContinuation<Void, Error>)] = [:]
  private var sleeperWaiters: [CheckedContinuation<Void, Never>] = []

  /// 默认从真实的现在开始（毫秒精度）：Store 用真实时间给记录盖章，两者要在同一时间线上。
  init(start: Date = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000)) { current = start }

  var now: Date { lock.withLock { current } }
  var timing: Timing { Timing(now: { self.now }, sleep: { try await self.sleep($0) }) }
  var sleeperCount: Int { lock.withLock { sleepers.count } }

  func advance(_ duration: Duration) {
    let due: [CheckedContinuation<Void, Error>] = lock.withLock {
      current = current.addingTimeInterval(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
      let ready = sleepers.filter { $0.value.deadline <= current }
      for id in ready.keys { sleepers[id] = nil }
      return ready.values.map(\.continuation)
    }
    for continuation in due { continuation.resume() }
  }

  /// 等到至少有一个任务挂在 `sleep` 上（确保 `advance` 会真的唤醒它）。
  func waitForSleeper() async {
    if sleeperCount > 0 { return }
    await withCheckedContinuation { continuation in
      lock.lock()
      if !sleepers.isEmpty {
        lock.unlock()
        continuation.resume()
      } else {
        sleeperWaiters.append(continuation)
        lock.unlock()
      }
    }
  }

  private func sleep(_ duration: Duration) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        lock.lock()
        sleepers[id] = (current.addingTimeInterval(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18), continuation)
        let waiters = sleeperWaiters
        sleeperWaiters = []
        lock.unlock()
        for waiter in waiters { waiter.resume() }
      }
    } onCancel: {
      let continuation = lock.withLock { sleepers.removeValue(forKey: id)?.continuation }
      continuation?.resume(throwing: CancellationError())
    }
  }
}

/// 订阅表变更直到条件成立（事件驱动，配合测试的时间限制，不轮询）。
func eventually<T: Sendable>(
  _ store: CueStore, watching tables: Set<Table>, _ read: @escaping @Sendable (isolated CueStore) throws -> T,
  until predicate: @Sendable (T) -> Bool
) async throws -> T {
  for try await value in store.observe(tables, read) where predicate(value) { return value }
  throw CancellationError()
}
