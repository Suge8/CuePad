import CoreGraphics
import CueStore
import Foundation
import ImageIO
import SQLite3
import Synchronization
import UniformTypeIdentifiers

// Kit 与 App 的测试共用的支撑：临时库、独立 sqlite3 连接、测试图片、手动时钟、等待。

/// 临时目录里的真实库文件（目录的清理见 `TestLibraries`）。
public final class Fixture: @unchecked Sendable {
  public let directory = TestLibraries.makeDirectory()
  public var url: URL { directory.appending(path: "cuepad.db") }
  public let store: CueStore

  public init() throws {
    store = try CueStore(location: .isolated(directory))
  }
}

/// 测试用资料库的临时目录。库会被测试里的观察流、协调器、执行器一直持有到它们自己结束，
/// 删掉仍打开的库文件时 SQLite 报 "database integrity compromised … vnode unlinked while in use"；
/// 所以本次运行不删自己的目录，而是在下次运行开始时清掉已经结束的运行（进程已不在）留下的目录，连同还在里面跑的进程（`TestProcesses`）。
public enum TestLibraries {
  private static let root = FileManager.default.temporaryDirectory.appending(path: "cuepad-test-libraries", directoryHint: .isDirectory)
  private static let run: URL = {
    // 清理与本次运行无关，不挡着第一个要库的用例（可能在主线程上）
    Thread.detachNewThread { removeFinishedRuns() }
    return root.appending(path: "\(getpid())", directoryHint: .isDirectory)
  }()

  /// 本次运行里一个新的空目录。
  public static func makeDirectory() -> URL {
    let directory = run.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private static func removeFinishedRuns() {
    let finished = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { name in
      Int32(name).map { kill($0, 0) == -1 && errno == ESRCH } ?? false
    }.map { root.appending(path: $0) }
    #if os(macOS)
    TestProcesses.stop(under: finished)
    #endif
    for directory in finished { try? FileManager.default.removeItem(at: directory) }
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
    // 别的连接收尾（最后一个关掉时做检查点）的那一下读不进来：同 `exec` 等着，不当场报 locked
    sqlite3_busy_timeout(handle, 5000)
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
public func pngData(width: Int = 4, height: Int = 4, shade: CGFloat = 0.5) -> Data {
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

/// 截止永远不到的钟：测的不是超时本身的用例，给产品里等别的进程的时限（问版本、起进程到上桥……）用。
/// 这些等待取决于系统此刻多忙（机器很忙时一个进程起来要几十秒），用真钟就是和墙钟赛跑；真挂住由每个测试的统一时限报。
public let noDeadline = ManualTiming().timing

/// 手动推进的时钟：`now` 只在 `advance` 时前进，`sleep` 挂起到 `advance` 越过截止时间。
public final class ManualTiming: Sendable {
  private struct State {
    var current: Date
    var sleepers: [UUID: (deadline: Date, continuation: CheckedContinuation<Void, Error>)] = [:]
    var sleeperWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  }
  private let state: Mutex<State>

  /// 默认从真实的现在开始（毫秒精度）：Store 用真实时间给记录盖章，两者要在同一时间线上。
  public init(start: Date = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000)) {
    state = Mutex(State(current: start))
  }

  public var now: Date { state.withLock { $0.current } }
  public var timing: Timing {
    Timing(now: { self.now }, sleep: { try await self.sleep(for: $0) }, sleepUntil: { date in try await self.sleep(until: { _ in date }) })
  }
  public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

  public func advance(_ duration: Duration) {
    let due: [CheckedContinuation<Void, Error>] = state.withLock { state in
      state.current = state.current.addingTimeInterval(duration.seconds)
      let ready = state.sleepers.filter { $0.value.deadline <= state.current }
      for id in ready.keys { state.sleepers[id] = nil }
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
        let ready = state.withLock { state in
          if !state.sleepers.isEmpty || Task.isCancelled { return true }
          state.sleeperWaiters[id] = continuation
          return false
        }
        if ready { continuation.resume() }
      }
    } onCancel: {
      state.withLock { $0.sleeperWaiters.removeValue(forKey: id) }?.resume()
    }
  }

  private func sleep(for duration: Duration) async throws {
    try await sleep(until: { $0.addingTimeInterval(duration.seconds) })
  }

  /// 登记一个睡眠者，截止时刻由登记那一刻的 `current` 算出（按时长睡）或直接给定（睡到某一刻）。
  private func sleep(until deadline: @escaping @Sendable (Date) -> Date) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        // 取消可能发生在登记之前（此时 onCancel 找不到它），登记时要再看一次；截止时刻已过（钟在它睡下前就拨过了）的当场醒
        let waiters: [CheckedContinuation<Void, Never>]?? = state.withLock { state in
          if Task.isCancelled { return nil }
          let due = deadline(state.current)
          if due <= state.current { return .some(nil) }
          state.sleepers[id] = (due, continuation)
          defer { state.sleeperWaiters = [:] }
          return Array(state.sleeperWaiters.values)
        }
        guard let registered = waiters else { return continuation.resume(throwing: CancellationError()) }
        guard let waiters = registered else { return continuation.resume() }
        for waiter in waiters { waiter.resume() }
      }
    } onCancel: {
      state.withLock { $0.sleepers.removeValue(forKey: id)?.continuation }?.resume(throwing: CancellationError())
    }
  }
}

/// 等不到时抛出：写明在等什么，测试就停在这里（接着往下跑只会在别处空等）。
struct TimedOut: Error, CustomStringConvertible {
  let description: String
}

/// 条件等待的上限，只认一个来源：每个测试的统一时限（xc.sh 的 `TEST_TIME_LIMIT`，经 `CUEPAD_TEST_TIME_LIMIT` 交给测试进程），取它的九成。
/// 条件要等的常是别的进程起来、答话，机器很忙时那不是几秒的事，自带一个短的墙钟上限只会假失败；挂住了仍由统一时限兜底，
/// 取九成是让「等不到：X」这句话赶在它之前说出来。
public let conditionBudget: Duration = .seconds(Double(ProcessInfo.processInfo.environment["CUEPAD_TEST_TIME_LIMIT"].flatMap(Int.init) ?? 120) * 0.9)

/// 有界条件等待，只给没有事件可订阅的异步用（文件系统通知、socket、子进程、系统弹窗与布局、后台落盘）：
/// 条件一成立马上返回，到了上限抛 `TimedOut`。库里的变化用下面按读取订阅的那个。
public func eventually(_ what: String, _ condition: () async throws -> Bool) async throws {
  let deadline = ContinuousClock.now + conditionBudget
  while try await !condition() {
    guard ContinuousClock.now < deadline else { throw TimedOut(description: "等不到：\(what)") }
    try await Task.sleep(for: .milliseconds(10))
  }
}

/// 等"什么都不会发生"：负向断言（停止后不再领取、权限不对就不连、链接不跳转）没有事件可等，只能给一段固定时长再确认仍没发生。
/// 测试里固定时长的等待只经这里写，搜它就知道哪些断言靠时长（负载极高时可能假通过，不会假失败）。
public func quietPeriod(_ duration: Duration) async {
  try? await Task.sleep(for: duration)
}

/// 订阅读取直到条件成立（事件驱动，不轮询），到了上限抛 `TimedOut`。
public func eventually<T: Sendable & Equatable>(
  _ store: CueStore, _ read: @escaping @Sendable (isolated CueStore) throws -> T,
  until predicate: @escaping @Sendable (T) -> Bool
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask {
      for try await value in store.observe(read) where predicate(value) { return value }
      throw CancellationError()
    }
    group.addTask {
      try await Task.sleep(for: conditionBudget)
      throw TimedOut(description: "等不到：库里的读取满足条件")
    }
    defer { group.cancelAll() }
    return try await group.next()!
  }
}

struct RawError: Error { let message: String }

extension CueStore {
  /// 全部会话记录（测试核对用；界面按范围与页读，见 `piSessionPage`）。
  public func allPiSessionStates() throws -> [PiSessionState] {
    try piSessionPage(PiSessionQuery(limit: .max)).items.map(\.state)
  }
}
