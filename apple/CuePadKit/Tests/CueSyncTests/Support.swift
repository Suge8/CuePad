import CloudKit
import CoreGraphics
@_exported import CueTestSupport
import CueStore
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

@testable import CueSync




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
