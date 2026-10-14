import CloudKit
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
}
