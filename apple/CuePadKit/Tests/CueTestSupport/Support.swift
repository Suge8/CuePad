import CoreGraphics
import CueStore
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

// CueStore、CueSync、命令行测试共用的支撑：临时库、独立 sqlite3 连接、测试图片、手动时钟、事件驱动的等待。

/// 临时目录里的真实库文件（目录的清理见 `TestLibraries`）。
public final class Fixture: @unchecked Sendable {
  public let directory = TestLibraries.makeDirectory()
  public var url: URL { directory.appending(path: "cuepad.db") }
  public let store: CueStore

  public init() throws {
    store = try CueStore(url: directory.appending(path: "cuepad.db"))
  }
}

/// 测试用资料库的临时目录。库会被测试里的观察流、协调器、执行器一直持有到它们自己结束，
/// 删掉仍打开的库文件时 SQLite 报 "database integrity compromised … vnode unlinked while in use"；
/// 所以本次运行不删自己的目录，而是在下次运行开始时清掉已经结束的运行（进程已不在）留下的目录。
public enum TestLibraries {
  private static let root = FileManager.default.temporaryDirectory.appending(path: "cuepad-test-libraries", directoryHint: .isDirectory)
  private static let run: URL = {
    removeFinishedRuns()
    return root.appending(path: "\(getpid())", directoryHint: .isDirectory)
  }()

  /// 本次运行里一个新的空目录。
  public static func makeDirectory() -> URL {
    let directory = run.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private static func removeFinishedRuns() {
    let runs = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    for name in runs {
      guard let pid = Int32(name), kill(pid, 0) == -1, errno == ESRCH else { continue }
      try? FileManager.default.removeItem(at: root.appending(path: name))
    }
  }
}


/// 用独立的 sqlite3 连接直接读写库文件：构造并发场景、检查落盘格式。
public struct RawDB {
  public let path: String

  public init(_ url: URL) { path = url.path }

  public func exec(_ sql: String) throws {
    var handle: OpaquePointer?
    defer { sqlite3_close(handle) }
    guard sqlite3_open(path, &handle) == SQLITE_OK else { throw RawError(message: "open") }
    sqlite3_busy_timeout(handle, 5000)
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
      throw RawError(message: String(cString: sqlite3_errmsg(handle)))
    }
  }

  /// 每行每列按文本读出（NULL 为 "NULL"）。
  public func rows(_ sql: String) throws -> [[String]] {
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

  public func count(_ table: String) throws -> Int { Int(try rows("SELECT count(*) FROM \(table)")[0][0])! }
}

/// 纯色 PNG；`shade` 不同则字节不同。
public func pngData(width: Int, height: Int, shade: CGFloat = 0.5) -> Data {
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
public final class ManualTiming: @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date
  private var sleepers: [UUID: (deadline: Date, continuation: CheckedContinuation<Void, Error>)] = [:]
  private var sleeperWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

  /// 默认从真实的现在开始（毫秒精度）：Store 用真实时间给记录盖章，两者要在同一时间线上。
  public init(start: Date = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000)) { current = start }

  public var now: Date { lock.withLock { current } }
  public var timing: Timing { Timing(now: { self.now }, sleep: { try await self.sleep($0) }) }
  public var sleeperCount: Int { lock.withLock { sleepers.count } }

  public func advance(_ duration: Duration) {
    let due: [CheckedContinuation<Void, Error>] = lock.withLock {
      current = current.addingTimeInterval(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
      let ready = sleepers.filter { $0.value.deadline <= current }
      for id in ready.keys { sleepers[id] = nil }
      return ready.values.map(\.continuation)
    }
    for continuation in due { continuation.resume() }
  }

  /// 等到至少有一个任务挂在 `sleep` 上（确保 `advance` 会真的唤醒它）；被取消（如超出测试时限）时立即返回。
  public func waitForSleeper() async {
    if sleeperCount > 0 { return }
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        lock.lock()
        if !sleepers.isEmpty || Task.isCancelled {
          lock.unlock()
          continuation.resume()
        } else {
          sleeperWaiters[id] = continuation
          lock.unlock()
        }
      }
    } onCancel: {
      lock.withLock { sleeperWaiters.removeValue(forKey: id) }?.resume()
    }
  }

  private func sleep(_ duration: Duration) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        lock.lock()
        // 取消可能发生在登记之前（此时 onCancel 找不到它），登记时要再看一次
        if Task.isCancelled {
          lock.unlock()
          continuation.resume(throwing: CancellationError())
          return
        }
        sleepers[id] = (current.addingTimeInterval(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18), continuation)
        let waiters = sleeperWaiters.values
        sleeperWaiters = [:]
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
public func eventually<T: Sendable>(
  _ store: CueStore, watching tables: Set<Table>, _ read: @escaping @Sendable (isolated CueStore) throws -> T,
  until predicate: @Sendable (T) -> Bool
) async throws -> T {
  for try await value in store.observe(tables, read) where predicate(value) { return value }
  throw CancellationError()
}

public struct RawError: Error { public let message: String }

extension CueStore {
  /// 全部会话记录（测试核对用；界面按范围与页读，见 `piSessionPage`）。
  public func allPiSessionStates() throws -> [PiSessionState] {
    try piSessionPage(PiSessionQuery(limit: .max)).items.map(\.state)
  }
}
