import CoreGraphics
import CueStore
import Foundation
import ImageIO
import SQLite3
import Synchronization
import UniformTypeIdentifiers


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
    Thread.detachNewThread { removeFinishedRuns() }
    return root.appending(path: "\(getpid())", directoryHint: .isDirectory)
  }()

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

public let noDeadline = ManualTiming().timing

public final class ManualTiming: Sendable {
  private struct State {
    var current: Date
    var sleepers: [UUID: (deadline: Date, continuation: CheckedContinuation<Void, Error>)] = [:]
    var sleeperWaiters: [UUID: (deadline: Date?, continuation: CheckedContinuation<Void, Never>)] = [:]

    func hasSleeper(until deadline: Date?) -> Bool {
      sleepers.values.contains { deadline == nil || $0.deadline == deadline }
    }
  }
  private let state: Mutex<State>

  public init(start: Date = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000)) {
    state = Mutex(State(current: start))
  }

  public var now: Date { state.withLock { $0.current } }
  public var timing: Timing {
    Timing(now: { self.now }, sleep: { try await self.sleep(for: $0) }, sleepUntil: { date in try await self.sleep(until: { _ in date }) })
  }
  public var sleeperCount: Int { state.withLock { $0.sleepers.count } }
  public func hasSleeper(until deadline: Date) -> Bool { state.withLock { $0.hasSleeper(until: deadline) } }

  public func advance(_ duration: Duration) {
    let due: [CheckedContinuation<Void, Error>] = state.withLock { state in
      state.current = state.current.addingTimeInterval(duration.seconds)
      let ready = state.sleepers.filter { $0.value.deadline <= state.current }
      for id in ready.keys { state.sleepers[id] = nil }
      return ready.values.map(\.continuation)
    }
    for continuation in due { continuation.resume() }
  }

  public func waitForSleeper(until deadline: Date? = nil) async throws {
    try await bounded("手动钟上有人睡下") { await self.sleeperArrives(until: deadline) }
  }

  private func sleeperArrives(until deadline: Date?) async {
    if state.withLock({ $0.hasSleeper(until: deadline) }) { return }
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let ready = state.withLock { state in
          if state.hasSleeper(until: deadline) || Task.isCancelled { return true }
          state.sleeperWaiters[id] = (deadline, continuation)
          return false
        }
        if ready { continuation.resume() }
      }
    } onCancel: {
      state.withLock { $0.sleeperWaiters.removeValue(forKey: id) }?.continuation.resume()
    }
  }

  private func sleep(for duration: Duration) async throws {
    try await sleep(until: { $0.addingTimeInterval(duration.seconds) })
  }

  private func sleep(until deadline: @escaping @Sendable (Date) -> Date) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let waiters: [CheckedContinuation<Void, Never>]?? = state.withLock { state in
          if Task.isCancelled { return nil }
          let due = deadline(state.current)
          if due <= state.current { return .some(nil) }
          state.sleepers[id] = (due, continuation)
          let ready = state.sleeperWaiters.filter { state.hasSleeper(until: $0.value.deadline) }
          for waiter in ready.keys { state.sleeperWaiters[waiter] = nil }
          return ready.values.map(\.continuation)
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

public struct TimedOut: Error, CustomStringConvertible {
  public let description: String
  public init(description: String) { self.description = description }
}

public final class Signal: Sendable {
  private let raised = Atomic(false)
  public init() {}
  public func raise() { raised.store(true, ordering: .releasing) }
  public var isRaised: Bool { raised.load(ordering: .acquiring) }
}

/// 条件等待的上限，只认一个来源：每个测试的统一时限（xc.sh 的 `TEST_TIME_LIMIT`，经 `CUEPAD_TEST_TIME_LIMIT` 交给测试进程），取它的九成。
/// 条件要等的常是别的进程起来、答话，机器很忙时那不是几秒的事，自带一个短的墙钟上限只会假失败；挂住了仍由统一时限兜底，
/// 取九成是让「等不到：X」这句话赶在它之前说出来。
public let conditionBudget: Duration = .seconds(Double(ProcessInfo.processInfo.environment["CUEPAD_TEST_TIME_LIMIT"].flatMap(Int.init) ?? 120) * 0.9)

public func bounded<T: Sendable>(_ what: String, _ wait: @escaping @Sendable () async throws -> T) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await wait() }
    group.addTask {
      try await Task.sleep(for: conditionBudget)
      throw TimedOut(description: "等不到：\(what)")
    }
    defer { group.cancelAll() }
    return try await group.next()!
  }
}

/// 同步占住当前（主）线程，直到 `signal` 或 `conditionBudget` 到。轮询而不阻塞等：主线程阻塞等默认级线程会被
/// Thread Performance Checker 报优先级反转，iOS 模拟器上 xcodebuild 随后收集诊断要卡满 600 秒。
public func holdThread(until signal: DispatchSemaphore) -> Bool {
  let deadline = DispatchTime.now() + Double(conditionBudget.components.seconds)
  while signal.wait(timeout: .now()) != .success {
    guard DispatchTime.now() < deadline else { return false }
    usleep(1_000)
  }
  return true
}

public func eventually(_ what: String, _ condition: () async throws -> Bool) async throws {
  let deadline = ContinuousClock.now + conditionBudget
  while try await !condition() {
    guard ContinuousClock.now < deadline else { throw TimedOut(description: "等不到：\(what)") }
    try await Task.sleep(for: .milliseconds(10))
  }
}

public func quietPeriod(_ duration: Duration) async {
  try? await Task.sleep(for: duration)
}

public func nextMillisecond() async {
  let start = Date.timeIntervalSinceReferenceDate
  while Date.timeIntervalSinceReferenceDate - start < 0.002 { await Task.yield() }
}

public func eventually<T: Sendable & Equatable>(
  _ store: CueStore, _ read: @escaping @Sendable (isolated CueStore) throws -> T,
  subscribed: Signal? = nil, until predicate: @escaping @Sendable (T) -> Bool
) async throws -> T {
  try await bounded("库里的读取满足条件") {
    var first = true
    for try await value in store.observe(read) {
      if first { first = false; subscribed?.raise() }
      if predicate(value) { return value }
    }
    throw CancellationError()
  }
}

struct RawError: Error { let message: String }

extension CueStore {
  public func allSessionStates() throws -> [SessionState] {
    try sessionPage(SessionQuery(limit: .max)).items.map(\.state)
  }
}
