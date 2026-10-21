import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

/// 最低对端版本（`PeerFloor`）：云端门槛高于这台能同步的结构版本就停下、本机内容与改动都留着；
/// 开始上传前门槛低于这台要求的就抬上去，只升不降。
@Suite struct PeerFloorTests {
  let rig = try! Rig()
  var store: CueStore { rig.store }
  static let supported = CueStore.supportedSchemaVersions

  static func floor(_ version: Int) -> CKRecord {
    let record = CKRecord(recordType: PeerFloor.recordType, recordID: PeerFloor(zoneID: testZone).id)
    record[PeerFloor.field] = version as NSNumber
    return record
  }

  @Test func 运行中别的设备把门槛抬过这台_那一页不应用_改动不上传_换账号状态也不恢复() async throws {
    let mine = try await store.createCard(body: "本机写的")
    try await store.setSyncState(ZonePuller.tokenKey, Data("t0".utf8))
    let theirs = remoteRecord(.cards, cardFields(body: "新版写的", modifiedAt: 9_000_000_000_000))
    let zone = FakeZone([.success(ZoneChangeBatch(modifications: [theirs, Self.floor(Self.supported.upperBound + 1)], deletions: [], token: Data("t1".utf8), moreComing: false))])

    await #expect(throws: SyncPaused.self) { try await ZonePuller(source: zone, coordinator: rig.coordinator).pull() }

    #expect(await rig.coordinator.status == .outdated)
    #expect(try await store.card(theirs.recordID.recordName.uuid) == nil)
    #expect(try await store.syncState(ZonePuller.tokenKey) == Data("t0".utf8))  // 更新后从这页接着拉
    #expect(try await store.card(mine.id)?.body == "本机写的")
    #expect(await rig.coordinator.nextBatch(first: [], limit: 400) == nil)
    await rig.coordinator.accountStatus(.noAccount)
    await rig.coordinator.accountStatus(.available)
    #expect(await rig.coordinator.status == .outdated)
  }

  @Test func 开始上传前对门槛_没有就写上这台要求的_只升不降_高于这台的停下() async throws {
    let empty = FloorCloud()
    try await PeerFloor(zoneID: testZone).settle(empty, coordinator: rig.coordinator)
    #expect(await empty.version == Self.supported.lowerBound)

    let higher = FloorCloud(Self.floor(Self.supported.upperBound))
    try await PeerFloor(zoneID: testZone).settle(higher, coordinator: rig.coordinator)
    #expect(await higher.version == Self.supported.upperBound)
    #expect(await higher.uploads == 0)

    // 读的时候还没有，写的时候别的设备抢先写了更高的：按服务器的来，不降回去
    let racing = FloorCloud(racing: Self.floor(Self.supported.upperBound))
    try await PeerFloor(zoneID: testZone).settle(racing, coordinator: rig.coordinator)
    #expect(await racing.version == Self.supported.upperBound)

    let ahead = FloorCloud(Self.floor(Self.supported.upperBound + 1))
    await #expect(throws: SyncPaused.self) { try await PeerFloor(zoneID: testZone).settle(ahead, coordinator: rig.coordinator) }
    #expect(await rig.coordinator.status == .outdated)
    #expect(await ahead.uploads == 0)
  }
}

/// 只有门槛那一条的服务器：`racing` 是第一次写入前别的设备抢先写下的那条（这次写入以版本冲突被拒）。
private actor FloorCloud: ZoneChangeSource, RecordUploader {
  private var floor: CKRecord?
  private var racing: CKRecord?
  private(set) var uploads = 0
  var version: Int? { floor.flatMap { PeerFloor.version(in: [$0]) } }

  init(_ floor: CKRecord? = nil, racing: CKRecord? = nil) {
    self.floor = floor
    self.racing = racing
  }

  func changes(since token: Data?, keys: [String]?) async throws -> ZoneChangeBatch {
    ZoneChangeBatch(modifications: [], deletions: [], token: Data(), moreComing: false)
  }

  func records(_ ids: [CKRecord.ID]) async throws -> [CKRecord] { floor.map { [$0] } ?? [] }

  func upload(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> SentRecords {
    uploads += 1
    if let racing {
      floor = racing
      self.racing = nil
      return SentRecords(failedSaves: [(saving[0], CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: racing]))])
    }
    floor = saving[0]
    return SentRecords(saved: saving)
  }

  func saveZone() async throws {}
}

extension String {
  fileprivate var uuid: UUID { UUID(uuidString: self)! }
}
