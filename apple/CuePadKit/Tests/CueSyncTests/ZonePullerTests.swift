import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

/// 没有令牌时（新装、令牌过期）按版本对账：不把整个同步区的正文下载一遍，
/// 只取本机没有或较旧的；本机推送过而服务器上已没有的，按在别处删掉处理；之后从存在库里的令牌增量拉。
@Suite struct ZonePullerTests {
  let rig = try! Rig()
  var store: CueStore { rig.store }

  private func page(_ token: String, _ records: [CKRecord] = [], more: Bool = false) -> Result<ZoneChangeBatch, any Error> {
    .success(ZoneChangeBatch(modifications: records, deletions: [], token: Data(token.utf8), moreComing: more))
  }

  /// 只带版本的那份（对账那一遍服务器给的样子）。
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

    #expect(await zone.calls.map(\.keys) == [ZonePuller.versionKeys, ZonePuller.versionKeys, ZonePuller.fieldsWithoutFiles])
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

  /// 拉到的一页没能应用（这里是期间换了账号、停下来等你决定）：令牌不前移，之后从同一处再拉。
  @Test func aPageThatWasNotAppliedDoesNotMoveTheToken() async throws {
    await rig.coordinator.account("user-a")
    try await store.setSyncState(ZonePuller.tokenKey, Data("t0".utf8))
    let fresh = remoteRecord(.cards, cardFields(body: "别处新建", modifiedAt: 2_000))
    let zone = SwitchingZone(page: ZoneChangeBatch(modifications: [fresh], deletions: [], token: Data("t1".utf8), moreComing: false), coordinator: rig.coordinator)

    await #expect(throws: (any Error).self) { try await ZonePuller(source: zone, coordinator: rig.coordinator).pull() }

    #expect(try await store.syncState(ZonePuller.tokenKey) == Data("t0".utf8))
    #expect(try await store.cards(in: Project.defaultID).isEmpty)
  }

  /// 同时来的几次拉取一个接一个跑：不会两个同时拉、用同一个令牌拉两遍。
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

  /// 拉一页时那头换了账号。
  actor SwitchingZone: ZoneChangeSource {
    let page: ZoneChangeBatch
    let coordinator: SyncCoordinator
    init(page: ZoneChangeBatch, coordinator: SyncCoordinator) {
      self.page = page
      self.coordinator = coordinator
    }
    func changes(since token: Data?, keys: [String]) async throws -> ZoneChangeBatch {
      await coordinator.account("user-b")
      return page
    }
    func records(_ ids: [CKRecord.ID]) async throws -> [CKRecord] { [] }
  }

  /// 每次给一页空变化、令牌加一，记下同时在拉的最多几个与每次带的令牌。
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
