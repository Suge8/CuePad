import CloudKit
@_exported import CueTestSupport
import CueStore
import Foundation

@testable import CueSync

/// 按顺序回放的同步区替身：记下每次被要的令牌与要哪些字段（nil：整条），以及每次按 ID 取了哪些记录。
actor FakeZone: ZoneChangeSource {
  private(set) var calls: [(token: Data?, keys: [String]?)] = []
  private(set) var fetches: [[CKRecord.ID]] = []
  private var responses: [Result<ZoneChangeBatch, any Error>]
  /// 按 ID 取整条记录时的服务器内容。
  var server: [CKRecord.ID: CKRecord] = [:]

  init(_ responses: [Result<ZoneChangeBatch, any Error>], server: [CKRecord] = []) {
    self.responses = responses
    self.server = Dictionary(uniqueKeysWithValues: server.map { ($0.recordID, $0) })
  }

  func changes(since token: Data?, keys: [String]) async throws -> ZoneChangeBatch {
    calls.append((token, keys))
    return try responses.removeFirst().get()
  }

  func records(_ ids: [CKRecord.ID]) async throws -> [CKRecord] {
    fetches.append(ids)
    return ids.compactMap { server[$0] }
  }
}

/// 收下一切的服务器替身：记下每批上传了什么；`holding` 时第一批挂住，直到 `release`。
actor FakeUploader: RecordUploader {
  private(set) var batches: [(saves: [String], deletes: [String])] = []
  private var gate: CheckedContinuation<Void, Never>?
  private var holding: Bool
  private var watchers: [(id: UUID, check: @Sendable ([(saves: [String], deletes: [String])]) -> Bool, continuation: CheckedContinuation<Void, Never>)] = []

  init(holding: Bool = false) { self.holding = holding }

  func upload(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> SentRecords {
    batches.append((saving.map(\.recordID.recordName), deleting.map(\.recordName)))
    let ready = watchers.filter { $0.check(batches) }
    watchers.removeAll { $0.check(batches) }
    for watcher in ready { watcher.continuation.resume() }
    if holding {
      holding = false
      await withCheckedContinuation { gate = $0 }
    }
    return SentRecords(saved: saving, deleted: deleting)
  }

  func saveZone() async throws {}

  func release() {
    gate?.resume()
    gate = nil
  }

  /// 等到上传过的批次满足条件；被取消（超出测试时限）时放手，测试照常结束、报出超时，不挂住整个测试进程。
  func waitUntil(_ check: @escaping @Sendable ([(saves: [String], deletes: [String])]) -> Bool) async {
    if check(batches) { return }
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled { return continuation.resume() }
        watchers.append((id, check, continuation))
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
  }

  private func cancel(_ id: UUID) {
    watchers.first { $0.id == id }?.continuation.resume()
    watchers.removeAll { $0.id == id }
  }

  func uploaded(_ name: String) async { await waitUntil { $0.contains { $0.saves.contains(name) } } }
  func deleted(_ name: String) async { await waitUntil { $0.contains { $0.deletes.contains(name) } } }
}

let testZone = CKRecordZone.ID(zoneName: "CuePadTest", ownerName: CKCurrentUserDefaultName)

/// 一套 store + 同步协调器。待推送就是库里推导的那一份（`pendingSync`）。
struct Rig {
  let fixture: Fixture
  let coordinator: SyncCoordinator
  var store: CueStore { fixture.store }

  init() throws {
    fixture = try Fixture()
    coordinator = SyncCoordinator(store: fixture.store, zoneID: testZone)
  }

  func recordID(_ id: UUID) -> CKRecord.ID { CKRecord.ID(recordName: id.uuidString.lowercased(), zoneID: testZone) }

  /// 模拟服务器接受了此刻所有待推送的保存与删除，返回上传的记录。
  @discardableResult
  func simulatePush() async throws -> [CKRecord] {
    let batch = try await coordinator.nextBatch(.pending(excluding: []), limit: .max)
    guard !batch.isEmpty else { return [] }
    _ = await coordinator.sent(SentRecords(saved: batch.saves, deleted: batch.deletes))
    return batch.saves
  }

  /// 此刻待推送的 (保存, 删除) 记录名。
  func reconcileDelta() async throws -> (saves: Set<String>, deletes: Set<String>) {
    let pending = try await store.pendingSync()
    return (Set(pending.saves.map(\.id)), Set(pending.deletes))
  }

  func id(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }
}

/// 构造"远端"记录：给出字段，得到带记录类型与名称的 CKRecord。
func remoteRecord(_ table: Table, id: UUID = UUID(), _ fields: [String: SQLValue]) -> CKRecord {
  var all = fields
  all["id"] = .text(id.uuidString.lowercased())
  return RecordMapper.record(from: SyncRow(table: table, fields: all), zoneID: testZone)
}

func projectFields(name: String, modifiedAt: Int64) -> [String: SQLValue] {
  [
    "name": .text(name), "icon": .null, "color": .text("#111"), "isPinned": .int(0),
    "deletedAt": .null, "createdAt": .int(1_000), "modifiedAt": .int(modifiedAt),
  ]
}

func cardFields(
  project: UUID = Project.defaultID, body: String, modifiedAt: Int64, sortKey: String = "V", conflictOf: UUID? = nil
) -> [String: SQLValue] {
  [
    "projectID": .text(project.uuidString.lowercased()), "body": .text(body),
    "isPinned": .int(0), "variableValues": .text("{}"),
    "sortKey": .text(sortKey), "deletedAt": .null, "createdAt": .int(1_000), "modifiedAt": .int(modifiedAt),
    "conflictOf": conflictOf.map { .text($0.uuidString.lowercased()) } ?? .null,
  ]
}

func sendFields(kind: String, modifiedAt: Int64) -> [String: SQLValue] {
  [
    "content": .text("snapshot"), "targetKind": .text(kind), "targetName": .text("somewhere"),
    "targetRef": .null, "cardID": .null, "sentAt": .int(2_000), "modifiedAt": .int(modifiedAt),
  ]
}

/// 两台"设备"之间的假云：把一端此刻的待推送交给另一端（`pulled`），并回报发送成功。
/// 附件同真的一样分两路：记录不带文件先到，文件经接收端的 `FileFetcher` 从云里取。
struct Loopback {
  let a: Rig
  let b: Rig
  let cloud = SimulatedCloud()

  /// 一来一回：a 的待推送到 b，再 b 的到 a。
  func exchange() async throws {
    try await deliver(from: a, to: b)
    try await deliver(from: b, to: a)
  }

  func deliver(from: Rig, to: Rig) async throws {
    let batch = try await from.coordinator.nextBatch(.pending(excluding: []), limit: .max)
    guard !batch.isEmpty else { return }
    let deletions: [(id: CKRecord.ID, recordType: String)] = try batch.deletes.compactMap { id in
      let type = try RawDB(from.fixture.url).rows("SELECT recordType FROM syncRecords WHERE recordName = '\(id.recordName)'").first?[0]
      return type.map { (id, $0) }
    }
    _ = await from.coordinator.sent(SentRecords(saved: batch.saves, deleted: batch.deletes))
    try await to.coordinator.pulled(batch.saves, deletions)
    try await deliverFiles(from: from, to: to)
  }

  private func deliverFiles(from: Rig, to: Rig) async throws {
    for name in try await from.store.pendingAttachments() {
      guard let record = try await from.coordinator.takeFile(name), let key = RecordMapper.row(from: record)?.attachmentKey else { continue }
      _ = await from.coordinator.sent(await cloud.uploadFile(record) { _ in })
      await from.coordinator.fileDone(name)
      try await to.coordinator.pulled([record.withoutFile], [])
      let fetcher = FileFetcher(cloud: cloud, coordinator: to.coordinator, board: TransferBoard())
      await fetcher.start()
      _ = try await fetcher.fetch(key)
      await fetcher.stop()
    }
  }
}

extension SyncCoordinator {
  /// 一批上传的结果（批就是结果里提到的这些记录）。
  func sent(_ sent: SentRecords) async -> SendOutcome {
    await self.sent(sent, for: OutgoingBatch(saves: sent.saved + sent.failedSaves.map(\.record), deletes: sent.deleted + sent.failedDeletes.map(\.id)))
  }
}
