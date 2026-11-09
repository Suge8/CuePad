import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

@Suite struct ZonePullerTests {
  let rig = try! Rig()
  var store: CueStore { rig.store }

  private func page(_ token: String, _ records: [CKRecord] = [], more: Bool = false) -> Result<ZoneChangeBatch, any Error> {
    .success(ZoneChangeBatch(modifications: records, deletions: [], token: Data(token.utf8), moreComing: more))
  }

  private func version(of record: CKRecord) -> CKRecord {
    let stub = CKRecord(recordType: record.recordType, recordID: record.recordID)
    stub["modifiedAt"] = record["modifiedAt"]
    return stub
  }

  @Test func catchingUpFetchesOnlyWhatIsNewerAndThenPullsFromTheSavedToken() async throws {
    let same = try await store.createCard(body: "已同步")
    let stale = try await store.createCard(body: "本机旧版")
    try await rig.simulatePush()
    let sameOnServer = try #require(try await rig.coordinator.record(for: rig.recordID(same.id)))
    let home = try #require(try await rig.coordinator.record(for: rig.recordID(Project.defaultID)))
    let newer = remoteRecord(.cards, id: stale.id, cardFields(body: "别处改过", modifiedAt: 9_000_000_000_000))
    let fresh = remoteRecord(.cards, cardFields(body: "别处新建", modifiedAt: 2_000))
    let zone = FakeZone(
      [page("v1", [version(of: home), version(of: sameOnServer), version(of: newer)], more: true), page("v2", [version(of: fresh)]), page("t1")],
      server: [home, sameOnServer, newer, fresh])
    #expect(await rig.coordinator.state.reconciled == false)

    try await ZonePuller(source: zone, coordinator: rig.coordinator).pull()

    let keys = await zone.calls.map { Set($0.keys ?? []) }
    #expect(keys.count == 3)
    #expect(!keys[0].contains("body") && !keys[1].contains("body"))  // 对账那两页只要版本
    #expect(keys[2].contains("body") && !keys[2].contains("file"))  // 补取要正文，不带附件文件
    #expect(await zone.calls.last?.token == Data("v2".utf8))
    #expect(Set(await zone.fetches.flatMap { $0 }) == [newer.recordID, fresh.recordID])  // 已同步的那条不取
    #expect(Set(try await store.cards(in: Project.defaultID).map(\.body)) == ["已同步", "别处改过", "别处新建"])
    #expect(try await store.syncState(ZonePuller.tokenKey) == Data("t1".utf8))
    #expect(await rig.coordinator.state.reconciled)  // 对过一遍：别的设备写下的事实都到了
  }

  @Test func recordsPushedBeforeButGoneFromTheServerAreDeletedAndUnpushedOnesKept() async throws {
    let kept = try await store.createCard(body: "还在")
    let goneElsewhere = try await store.createCard(body: "别处删了")
    try await rig.simulatePush()
    let unpushed = try await store.createCard(body: "本机新写的")
    let keptOnServer = try #require(try await rig.coordinator.record(for: rig.recordID(kept.id)))
    let home = try #require(try await rig.coordinator.record(for: rig.recordID(Project.defaultID)))
    let zone = FakeZone([page("v1", [version(of: home), version(of: keptOnServer)]), page("t1")])

    try await ZonePuller(source: zone, coordinator: rig.coordinator).pull()

    #expect(Set(try await store.cards(in: Project.defaultID).map(\.id)) == [kept.id, unpushed.id])
    #expect(!(try await rig.reconcileDelta().deletes.contains(rig.id(goneElsewhere.id))))  // 不再向服务器删一遍
  }

  @Test func anExpiredTokenIsDroppedAndTheZoneIsCaughtUpAgain() async throws {
    try await store.setSyncState(ZonePuller.tokenKey, Data("old".utf8))
    let fresh = remoteRecord(.cards, cardFields(body: "期间新建", modifiedAt: 2_000))
    let zone = FakeZone([.failure(CKError(.changeTokenExpired)), page("v1", [version(of: fresh)]), page("t1")], server: [fresh])

    try await ZonePuller(source: zone, coordinator: rig.coordinator).pull()

    #expect(await zone.calls.first?.token == Data("old".utf8))
    #expect(try await store.cards(in: Project.defaultID).map(\.body) == ["期间新建"])
    #expect(try await store.syncState(ZonePuller.tokenKey) == Data("t1".utf8))
  }

  @Test func aRecordDeletedWhileTheZoneWasBeingScannedIsDeletedHere() async throws {
    let card = try await store.createCard(body: "翻的途中在别处删了")
    try await rig.simulatePush()
    let onServer = try #require(try await rig.coordinator.record(for: rig.recordID(card.id)))
    let deleted = ZoneChangeBatch(modifications: [], deletions: [(onServer.recordID, "cards")], token: Data("v2".utf8), moreComing: false)
    let zone = FakeZone([page("v1", [version(of: onServer)], more: true), .success(deleted), page("t1")])

    try await ZonePuller(source: zone, coordinator: rig.coordinator).pull()

    #expect(try await store.cards(in: Project.defaultID).isEmpty)
  }

  @Test func aPageThatWasNotAppliedDoesNotMoveTheToken() async throws {
    let gate = AccountGate()
    await rig.coordinator.use(gate)
    await rig.coordinator.account("user-a", from: gate.begin(closing: false))
    try await store.setSyncState(ZonePuller.tokenKey, Data("t0".utf8))
    let fresh = remoteRecord(.cards, cardFields(body: "别处新建", modifiedAt: 2_000))
    let zone = SwitchingZone(page: ZoneChangeBatch(modifications: [fresh], deletions: [], token: Data("t1".utf8), moreComing: false), coordinator: rig.coordinator, gate: gate)

    await #expect(throws: (any Error).self) { try await ZonePuller(source: zone, coordinator: rig.coordinator).pull() }

    #expect(try await store.syncState(ZonePuller.tokenKey) == Data("t0".utf8))
    #expect(try await store.cards(in: Project.defaultID).isEmpty)
  }

  @Test func concurrentPullsRunOneAfterAnother() async throws {
    try await store.setSyncState(ZonePuller.tokenKey, Data("0".utf8))
    let zone = CountingZone()
    let puller = ZonePuller(source: zone, coordinator: rig.coordinator)

    await withThrowingTaskGroup { group in
      for _ in 0..<4 { group.addTask { try await puller.pull() } }
    }

    #expect(await zone.mostAtOnce == 1)
    let tokens = await zone.tokens
    #expect(Set(tokens).count == tokens.count)
  }

  actor SwitchingZone: ZoneChangeSource {
    let page: ZoneChangeBatch
    let coordinator: SyncCoordinator
    let gate: AccountGate
    init(page: ZoneChangeBatch, coordinator: SyncCoordinator, gate: AccountGate) {
      self.page = page
      self.coordinator = coordinator
      self.gate = gate
    }
    func changes(since token: Data?, keys: [String]) async throws -> ZoneChangeBatch {
      await coordinator.account("user-b", from: gate.begin(closing: false))
      return page
    }
    func records(_ ids: [CKRecord.ID]) async throws -> [CKRecord] { [] }
  }

  actor CountingZone: ZoneChangeSource {
    private var active = 0
    private(set) var mostAtOnce = 0
    private(set) var tokens: [String] = []
    func changes(since token: Data?, keys: [String]) async throws -> ZoneChangeBatch {
      active += 1
      mostAtOnce = max(mostAtOnce, active)
      let current = token.map { String(decoding: $0, as: UTF8.self) } ?? ""
      tokens.append(current)
      try await Task.sleep(for: .milliseconds(20))
      active -= 1
      return ZoneChangeBatch(modifications: [], deletions: [], token: Data(String((Int(current) ?? 0) + 1).utf8), moreComing: false)
    }
    func records(_ ids: [CKRecord.ID]) async throws -> [CKRecord] { [] }
  }
}
