import CloudKit
import CryptoKit
import CueStore
import Foundation
import Testing

@testable import CueSync

/// 没有令牌时（新装、从 CKSyncEngine 的版本升上来、令牌过期）按版本对账：不把整个同步区的正文下载一遍，
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
    let same = try await store.createCard(in: nil, body: "已同步")
    let stale = try await store.createCard(in: nil, body: "本机旧版")
    try await rig.simulatePush()
    let sameOnServer = try #require(await rig.coordinator.record(for: rig.recordID(same.id)))
    let newer = remoteRecord(.cards, id: stale.id, cardFields(project: nil, body: "别处改过", modifiedAt: 9_000_000_000_000))
    let fresh = remoteRecord(.cards, cardFields(project: nil, body: "别处新建", modifiedAt: 2_000))
    let zone = FakeZone(
      [page("v1", [version(of: sameOnServer), version(of: newer)], more: true), page("v2", [version(of: fresh)]), page("t1")],
      server: [sameOnServer, newer, fresh])

    try await ZonePuller(source: zone, coordinator: rig.coordinator).pull()

    #expect(await zone.calls.map(\.keys) == [ZonePuller.versionKeys, ZonePuller.versionKeys, nil])
    #expect(await zone.calls.last?.token == Data("v2".utf8))
    #expect(Set(await zone.fetches.flatMap { $0 }) == [newer.recordID, fresh.recordID])  // 已同步的那条不取
    #expect(Set(try await store.cards(in: nil).map(\.body)) == ["已同步", "别处改过", "别处新建"])
    #expect(try await store.syncState(ZonePuller.tokenKey) == Data("t1".utf8))
  }

  @Test func recordsPushedBeforeButGoneFromTheServerAreDeletedAndUnpushedOnesKept() async throws {
    let kept = try await store.createCard(in: nil, body: "还在")
    let goneElsewhere = try await store.createCard(in: nil, body: "别处删了")
    try await rig.simulatePush()
    let unpushed = try await store.createCard(in: nil, body: "本机新写的")
    let keptOnServer = try #require(await rig.coordinator.record(for: rig.recordID(kept.id)))
    let zone = FakeZone([page("v1", [version(of: keptOnServer)]), page("t1")])

    try await ZonePuller(source: zone, coordinator: rig.coordinator).pull()

    #expect(Set(try await store.cards(in: nil).map(\.id)) == [kept.id, unpushed.id])
    #expect(!(try await rig.reconcileDelta().deletes.contains(rig.id(goneElsewhere.id))))  // 不再向服务器删一遍
  }

  @Test func anExpiredTokenIsDroppedAndTheZoneIsCaughtUpAgain() async throws {
    try await store.setSyncState(ZonePuller.tokenKey, Data("old".utf8))
    let fresh = remoteRecord(.cards, cardFields(project: nil, body: "期间新建", modifiedAt: 2_000))
    let zone = FakeZone([.failure(CKError(.changeTokenExpired)), page("v1", [version(of: fresh)]), page("t1")], server: [fresh])

    try await ZonePuller(source: zone, coordinator: rig.coordinator).pull()

    #expect(await zone.calls.first?.token == Data("old".utf8))
    #expect(try await store.cards(in: nil).map(\.body) == ["期间新建"])
    #expect(try await store.syncState(ZonePuller.tokenKey) == Data("t1".utf8))
  }

  @Test func aRecordDeletedWhileTheZoneWasBeingScannedIsDeletedHere() async throws {
    let card = try await store.createCard(in: nil, body: "翻的途中在别处删了")
    try await rig.simulatePush()
    let onServer = try #require(await rig.coordinator.record(for: rig.recordID(card.id)))
    let deleted = ZoneChangeBatch(modifications: [], deletions: [(onServer.recordID, "cards")], token: Data("v2".utf8), moreComing: false)
    let zone = FakeZone([page("v1", [version(of: onServer)], more: true), .success(deleted), page("t1")])

    try await ZonePuller(source: zone, coordinator: rig.coordinator).pull()

    #expect(try await store.cards(in: nil).isEmpty)
  }

  /// 拉到的一页没能应用（这里是期间换了账号、停下来等你决定）：令牌不前移，之后从同一处再拉。
  @Test func aPageThatWasNotAppliedDoesNotMoveTheToken() async throws {
    await rig.coordinator.handle(.account("user-a"))
    try await store.setSyncState(ZonePuller.tokenKey, Data("t0".utf8))
    let fresh = remoteRecord(.cards, cardFields(project: nil, body: "别处新建", modifiedAt: 2_000))
    let zone = SwitchingZone(page: ZoneChangeBatch(modifications: [fresh], deletions: [], token: Data("t1".utf8), moreComing: false), coordinator: rig.coordinator)

    await #expect(throws: (any Error).self) { try await ZonePuller(source: zone, coordinator: rig.coordinator).pull() }

    #expect(try await store.syncState(ZonePuller.tokenKey) == Data("t0".utf8))
    #expect(try await store.cards(in: nil).isEmpty)
  }

  /// 带着文件的附件记录（`declaredHash` 不给就是内容的真哈希）。
  private func attachment(_ data: Data, declaredHash: String? = nil) throws -> CKRecord {
    let hash = declaredHash ?? SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let record = remoteRecord(.attachments, [
      "hash": .text(hash), "byteCount": .int(Int64(data.count)), "format": .text("png"), "createdAt": .int(1_000), "modifiedAt": .int(5_000),
    ])
    let file = rig.fixture.directory.appending(path: "download-\(UUID().uuidString)")
    try data.write(to: file)
    record["file"] = CKAsset(fileURL: file)
    return record
  }

  /// 本机写不进附件文件（这里是附件目录的位置被一个文件占着）：这一页没应用，令牌不前移；故障消除后再拉，文件落盘、令牌前移。
  @Test func anAttachmentThatCouldNotBeWrittenHereIsPulledAgainLater() async throws {
    try await store.setSyncState(ZonePuller.tokenKey, Data("t0".utf8))
    let data = pngData(width: 5, height: 5)
    let record = try attachment(data)
    let blocker = rig.fixture.directory.appending(path: "Attachments")
    try Data().write(to: blocker)
    let zone = FakeZone([page("t1", [record]), page("t1", [record])])
    let puller = ZonePuller(source: zone, coordinator: rig.coordinator)

    await #expect(throws: (any Error).self) { try await puller.pull() }
    #expect(try await store.syncState(ZonePuller.tokenKey) == Data("t0".utf8))

    try FileManager.default.removeItem(at: blocker)
    try await puller.pull()
    #expect(await zone.calls.map(\.token) == [Data("t0".utf8), Data("t0".utf8)])
    #expect(try store.files.original(hash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()) == data)
    #expect(try await store.syncState(ZonePuller.tokenKey) == Data("t1".utf8))
  }

  /// 对照：附件记录本身坏了（内容与哈希不符）不会自己变好，拒绝这一条，令牌照常前移。
  @Test func anAttachmentWhoseContentDoesNotMatchItsHashIsSkippedAndTheTokenMoves() async throws {
    try await store.setSyncState(ZonePuller.tokenKey, Data("t0".utf8))
    let record = try attachment(pngData(width: 5, height: 5), declaredHash: String(repeating: "a", count: 64))
    let zone = FakeZone([page("t1", [record])])

    try await ZonePuller(source: zone, coordinator: rig.coordinator).pull()

    #expect(try await store.syncState(ZonePuller.tokenKey) == Data("t1".utf8))
    #expect(try RawDB(rig.fixture.url).count("attachments") == 0)
    #expect(await rig.coordinator.issues.contains { $0.message.contains("已拒绝") })
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
    func changes(since token: Data?, keys: [String]?) async throws -> ZoneChangeBatch {
      await coordinator.handle(.account("user-b"))
      return page
    }
    func records(_ ids: [CKRecord.ID]) async throws -> [CKRecord] { [] }
  }

  /// 每次给一页空变化、令牌加一，记下同时在拉的最多几个与每次带的令牌。
  actor CountingZone: ZoneChangeSource {
    private var active = 0
    private(set) var mostAtOnce = 0
    private(set) var tokens: [String] = []
    func changes(since token: Data?, keys: [String]?) async throws -> ZoneChangeBatch {
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
