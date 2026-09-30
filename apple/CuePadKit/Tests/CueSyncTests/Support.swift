import CloudKit
import CoreGraphics
import CueStore
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

@testable import CueSync

/// 临时目录里的真实库文件；释放时清理。
final class Fixture: @unchecked Sendable {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "cuepad-sync-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
  var url: URL { directory.appending(path: "cuepad.db") }
  var attachments: URL { directory.appending(path: "Attachments", directoryHint: .isDirectory) }
  let store: CueStore

  init() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    store = try CueStore(url: directory.appending(path: "cuepad.db"))
  }

  deinit { try? FileManager.default.removeItem(at: directory) }
}

/// 独立 sqlite3 连接：设定时间戳、检查落盘内容。
struct RawDB {
  let path: String
  init(_ url: URL) { path = url.path }

  func exec(_ sql: String) throws {
    var handle: OpaquePointer?
    defer { sqlite3_close(handle) }
    guard sqlite3_open(path, &handle) == SQLITE_OK else { throw RawError() }
    sqlite3_busy_timeout(handle, 5000)
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw RawError() }
  }

  func rows(_ sql: String) throws -> [[String]] {
    var handle: OpaquePointer?
    defer { sqlite3_close(handle) }
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw RawError() }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw RawError() }
    defer { sqlite3_finalize(statement) }
    var result: [[String]] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      result.append((0..<sqlite3_column_count(statement)).map { column in
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "NULL"
      })
    }
    return result
  }

  func count(_ table: String) throws -> Int { Int(try rows("SELECT count(*) FROM \(table)")[0][0])! }
}

struct RawError: Error {}

/// 记录同步逻辑向引擎登记了什么；替代真实 CKSyncEngine 的待办状态。
actor FakeQueue: ChangeQueue {
  private(set) var saves: [String] = []
  private(set) var deletes: [String] = []
  private(set) var zoneRequests = 0
  private var waiters: [(check: @Sendable ([String], [String]) -> Bool, continuation: CheckedContinuation<Void, Never>)] = []

  func enqueue(saves: [CKRecord.ID], deletes: [CKRecord.ID]) {
    self.saves += saves.map(\.recordName)
    self.deletes += deletes.map(\.recordName)
    let ready = waiters.filter { $0.check(self.saves, self.deletes) }
    waiters = waiters.filter { !$0.check(self.saves, self.deletes) }
    for waiter in ready { waiter.continuation.resume() }
  }

  func ensureZone(_ zoneID: CKRecordZone.ID) { zoneRequests += 1 }

  func clear() {
    saves = []
    deletes = []
  }

  /// 原子地取走当前全部待办（取和清之间不会漏掉新登记的）。
  func take() -> (saves: Set<String>, deletes: Set<String>) {
    defer { clear() }
    return (Set(saves), Set(deletes))
  }

  /// 只丢弃指定的待办：模拟服务器已确认这些记录，之前重复登记的一并去掉。
  func discard(saves discarded: Set<String>, deletes gone: Set<String>) {
    saves.removeAll { discarded.contains($0) }
    deletes.removeAll { gone.contains($0) }
  }

  func waitUntil(_ check: @escaping @Sendable ([String], [String]) -> Bool) async {
    if check(saves, deletes) { return }
    await withCheckedContinuation { waiters.append((check, $0)) }
  }
}

let testZone = CKRecordZone.ID(zoneName: "CuePadTest", ownerName: CKCurrentUserDefaultName)

/// 一套 store + 同步协调器 + 假队列。
struct Rig {
  let fixture: Fixture
  let queue: FakeQueue
  let coordinator: SyncCoordinator
  var store: CueStore { fixture.store }

  init() throws {
    fixture = try Fixture()
    queue = FakeQueue()
    coordinator = SyncCoordinator(store: fixture.store, queue: queue, zoneID: testZone)
  }

  func recordID(_ id: UUID) -> CKRecord.ID { CKRecord.ID(recordName: id.uuidString.lowercased(), zoneID: testZone) }

  /// 模拟服务器接受了所有已登记的保存与删除。
  func simulatePush() async throws {
    var saved: [CKRecord] = []
    for name in Set(await queue.saves) {
      if let record = await coordinator.record(for: CKRecord.ID(recordName: name, zoneID: testZone)) { saved.append(record) }
    }
    let deleted = Set(await queue.deletes).map { CKRecord.ID(recordName: $0, zoneID: testZone) }
    await queue.clear()
    await coordinator.handle(.sent(saved: saved, failedSaves: [], deleted: deleted, failedDeletes: []))
  }

  /// 重新对账，返回新登记的 (保存, 删除) 记录名。
  func reconcileDelta() async throws -> (saves: Set<String>, deletes: Set<String>) {
    await queue.clear()
    try await coordinator.reconcile()
    return (Set(await queue.saves), Set(await queue.deletes))
  }

  func id(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }
}

/// 构造"远端"记录：给出字段，得到带记录类型与名称的 CKRecord。
func remoteRecord(_ table: Table, id: UUID = UUID(), _ fields: [String: SQLValue]) -> CKRecord {
  var all = fields
  all["id"] = .text(id.uuidString.lowercased())
  return RecordMapper.record(from: SyncRow(table: table, fields: all), zoneID: testZone)
}

func projectFields(name: String, modifiedAt: Int64, sortKey: String = "V") -> [String: SQLValue] {
  [
    "name": .text(name), "icon": .null, "color": .text("#111"), "sortKey": .text(sortKey), "isPinned": .int(0),
    "deletedAt": .null, "createdAt": .int(1_000), "modifiedAt": .int(modifiedAt), "goalCardID": .null,
  ]
}

func cardFields(
  project: UUID?, body: String, modifiedAt: Int64, sortKey: String = "V", numbering: String = "none",
  conflictOf: UUID? = nil
) -> [String: SQLValue] {
  [
    "projectID": project.map { .text($0.uuidString.lowercased()) } ?? .null, "body": .text(body),
    "numbering": .text(numbering), "isPinned": .int(0), "variableValues": .text("{}"),
    "sortKey": .text(sortKey), "deletedAt": .null, "createdAt": .int(1_000), "modifiedAt": .int(modifiedAt),
    "conflictOf": conflictOf.map { .text($0.uuidString.lowercased()) } ?? .null,
  ]
}

func sendFields(kind: String, modifiedAt: Int64) -> [String: SQLValue] {
  [
    "content": .text("snapshot"), "targetKind": .text(kind), "targetName": .text("somewhere"),
    "targetRef": .null, "cardID": .null, "taskID": .null, "sentAt": .int(2_000), "modifiedAt": .int(modifiedAt),
  ]
}

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
  private var sleeperWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

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

  /// 等到至少有一个任务挂在 `sleep` 上（确保 `advance` 会真的唤醒它）；被取消（如超出测试时限）时立即返回。
  func waitForSleeper() async {
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
func eventually<T: Sendable>(
  _ store: CueStore, watching tables: Set<Table>, _ read: @escaping @Sendable (isolated CueStore) throws -> T,
  until predicate: @Sendable (T) -> Bool
) async throws -> T {
  for try await value in store.observe(tables, read) where predicate(value) { return value }
  throw CancellationError()
}


/// 两台"设备"之间的假云：把一端已登记的保存与删除交给另一端（`fetched`），并回报发送成功。
struct Loopback {
  let a: Rig
  let b: Rig
  var beforeFetch: @Sendable () -> Void = {}
  var beforeApply: @Sendable () -> Void = {}

  /// 一来一回：a 的待办到 b，再 b 的到 a。
  func exchange() async throws {
    try await deliver(from: a, to: b)
    try await deliver(from: b, to: a)
  }

  func deliver(from: Rig, to: Rig) async throws {
    try await from.coordinator.reconcile()
    let (saves, deletes) = await from.queue.take()
    guard !saves.isEmpty || !deletes.isEmpty else { return }

    var records: [CKRecord] = []
    for name in saves.sorted() {
      if let record = await from.coordinator.record(for: CKRecord.ID(recordName: name, zoneID: testZone)) { records.append(record) }
    }
    let deletions: [(id: CKRecord.ID, recordType: String)] = try deletes.sorted().compactMap { name in
      let type = try RawDB(from.fixture.url).rows("SELECT recordType FROM syncRecords WHERE recordName = '\(name)'").first?[0]
      return type.map { (CKRecord.ID(recordName: name, zoneID: testZone), $0) }
    }
    beforeFetch()
    await from.coordinator.handle(.sent(
      saved: records, failedSaves: [], deleted: deletions.map(\.id), failedDeletes: []))
    await from.queue.discard(saves: saves, deletes: deletes)  // .sent 之前对账可能重复登记过
    beforeApply()
    await to.coordinator.handle(.fetched(modifications: records, deletions: deletions))
  }
}
