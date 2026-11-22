import CloudKit
@_exported import CueTestSupport
import CueStore
import Foundation

@testable import CueSync

actor FakeZone: ZoneChangeSource {
  private(set) var calls: [(token: Data?, keys: [String]?)] = []
  private(set) var fetches: [[CKRecord.ID]] = []
  private var responses: [Result<ZoneChangeBatch, any Error>]
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

actor FakeUploader: RecordUploader {
  private(set) var batches: [(saves: [String], deletes: [String])] = []
  private var gate: CheckedContinuation<Void, Never>?
  private var holding: Bool

  init(holding: Bool = false) { self.holding = holding }

  func upload(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> SentRecords {
    batches.append((saving.map(\.recordID.recordName), deleting.map(\.recordName)))
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

  func waitUntil(_ what: String, _ check: @escaping @Sendable ([(saves: [String], deletes: [String])]) -> Bool) async throws {
    try await eventually(what) { check(batches) }
  }

  func uploaded(_ name: String) async throws { try await waitUntil("上传出现 \(name)") { $0.contains { $0.saves.contains(name) } } }
  func deleted(_ name: String) async throws { try await waitUntil("删除出现 \(name)") { $0.contains { $0.deletes.contains(name) } } }
}

let testZone = CKRecordZone.ID(zoneName: "CuePadTest", ownerName: CKCurrentUserDefaultName)

struct Rig {
  let fixture: Fixture
  let coordinator: SyncCoordinator
  var store: CueStore { fixture.store }

  init() throws {
    fixture = try Fixture()
    coordinator = SyncCoordinator(store: fixture.store, zoneID: testZone)
  }

  func recordID(_ id: UUID) -> CKRecord.ID { CKRecord.ID(recordName: id.uuidString.lowercased(), zoneID: testZone) }

  @discardableResult
  func simulatePush() async throws -> [CKRecord] {
    var saved: [CKRecord] = []
    for lane in Lane.allCases {
      let batch = try await coordinator.nextBatch(lane, limit: .max)
      guard !batch.isEmpty else { continue }
      _ = await coordinator.sent(SentRecords(saved: batch.saves, deleted: batch.deletes))
      saved += batch.saves
    }
    return saved
  }

  func reconcileDelta() async throws -> (saves: Set<String>, deletes: Set<String>) {
    let pending = try await store.pendingSync()
    return (Set(pending.saves.map(\.id)), Set(pending.deletes))
  }

  func id(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }
}

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
  project: UUID = Project.defaultID, body: String, modifiedAt: Int64, sortKey: String = "V"
) -> [String: SQLValue] {
  [
    "projectID": .text(project.uuidString.lowercased()), "body": .text(body),
    "isPinned": .int(0), "variableValues": .text("{}"),
    "sortKey": .text(sortKey), "deletedAt": .null, "createdAt": .int(1_000), "modifiedAt": .int(modifiedAt),
    "conflictOf": .null,
  ]
}

func sendFields(kind: String, modifiedAt: Int64) -> [String: SQLValue] {
  [
    "content": .text("snapshot"), "targetKind": .text(kind), "targetName": .text("somewhere"),
    "targetRef": .null, "cardID": .null, "sentAt": .int(2_000), "modifiedAt": .int(modifiedAt),
  ]
}

struct Loopback {
  let a: Rig
  let b: Rig
  let cloud = SimulatedCloud()

  func exchange() async throws {
    try await deliver(from: a, to: b)
    try await deliver(from: b, to: a)
  }

  func deliver(from: Rig, to: Rig, lanes: [Lane] = Lane.allCases) async throws {
    for lane in lanes { try await deliver(from: from, to: to, lane: lane) }
    try await deliverFiles(from: from, to: to)
  }

  private func deliver(from: Rig, to: Rig, lane: Lane) async throws {
    let batch = try await from.coordinator.nextBatch(lane, limit: .max)
    guard !batch.isEmpty else { return }
    let deletions: [(id: CKRecord.ID, recordType: String)] = try batch.deletes.compactMap { id in
      let type = try RawDB(from.fixture.url).rows("SELECT recordType FROM syncRecords WHERE recordName = '\(id.recordName)'").first?[0]
      return type.map { (id, $0) }
    }
    _ = await from.coordinator.sent(SentRecords(saved: batch.saves, deleted: batch.deletes))
    try await to.coordinator.pulled(batch.saves, deletions)
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
  func sent(_ sent: SentRecords) async -> SendOutcome {
    await self.sent(sent, for: OutgoingBatch(saves: sent.saved + sent.failedSaves.map(\.record), deletes: sent.deleted + sent.failedDeletes.map(\.id)))
  }
}
