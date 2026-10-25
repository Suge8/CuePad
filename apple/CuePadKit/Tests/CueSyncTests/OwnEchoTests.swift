import CloudKit
import CueStore
import Testing

@testable import CueSync

/// 用户在一台 Mac 上连续编辑同一条提示词：本机上传过的版本经拉取回到本机时，本机往往已有更新的编辑。
/// 回声不是别的设备的并发编辑，不能留下冲突副本。从同步入口（`CloudSync`）走，App 中途重启过。
@Suite(.timeLimit(.minutes(1))) struct OwnEchoTests {
  let fixture = try! Fixture()
  let cloud = EchoCloud()
  var store: CueStore { fixture.store }

  /// 上传已落账，本机又改了（还没传上去）、App 也重启过，之后拉取才带回那一版。
  @Test func anUploadedVersionPulledBackAfterALaterEditIsNotAConflict() async throws {
    let (sync, card) = try await syncedCard()
    try await edit(card, "第一版")
    #expect(await sync.send(recordNames: [name(card)]))

    try await expectEchoIgnored(card, after: sync)
  }

  /// 交出去的那一版服务器收下了、结果却没回到本机（回包丢失），App 重启、本机又改过，那一版经拉取回来。
  @Test func anUploadWhoseResultNeverArrivedIsNotAConflict() async throws {
    let (sync, card) = try await syncedCard()
    await cloud.loseNextResult()
    try await edit(card, "第一版")
    #expect(await !sync.send(recordNames: [name(card)]))

    try await expectEchoIgnored(card, after: sync)
  }

  /// 同步过一遍（有了令牌）、传上去了的一张卡。
  private func syncedCard() async throws -> (CloudSync, Card) {
    let sync = CloudSync(store: store) { cloud }
    await sync.start()
    try await sync.syncNow()
    let card = try await store.createCard(body: "base")
    #expect(await sync.send(recordNames: [name(card)]))
    return (sync, card)
  }

  /// 服务器上留着本机交出去的"第一版"；App 重启，本机改成"第二版"（上传挂住，服务器上还是第一版），拉回第一版。
  private func expectEchoIgnored(_ card: Card, after sync: CloudSync) async throws {
    await sync.stop()
    await cloud.hold()
    try await edit(card, "第二版")
    let restarted = CloudSync(store: store) { cloud }
    await restarted.start()
    try await restarted.syncNow()

    #expect(try await store.conflicts().isEmpty)
    #expect(try await store.card(card.id)?.body == "第二版")
    #expect(try await store.pendingSync().saves.map(\.id).contains(name(card)))  // 更新的版本仍待推送
    await cloud.release()
    await restarted.stop()
  }

  private func edit(_ card: Card, _ body: String) async throws {
    try await Task.sleep(for: .milliseconds(3))  // 修改时间是毫秒，每一版要落在不同的毫秒
    try await store.updateCard(card.id) { $0.body = body }
  }

  private func name(_ card: Card) -> String { card.id.uuidString.lowercased() }
}

/// 内存里的 iCloud（`SimulatedCloud`），上传能挂住（`hold`），也能收下后丢掉结果、报断网（`loseNextResult`）。
actor EchoCloud: SyncCloud {
  private let inner: SimulatedCloud
  private var holding = false
  private var held: [CheckedContinuation<Void, Never>] = []
  private var losesNextResult = false

  init() {
    let floor = CKRecord(recordType: PeerFloor.recordType, recordID: PeerFloor(zoneID: CloudSync.zoneID).id)
    floor[PeerFloor.field] = CueStore.supportedSchemaVersions.lowerBound as NSNumber
    inner = SimulatedCloud([floor])
  }

  func hold() { holding = true }

  func release() {
    holding = false
    held.forEach { $0.resume() }
    held = []
  }

  func loseNextResult() { losesNextResult = true }

  func upload(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> SentRecords {
    if holding { await withCheckedContinuation { held.append($0) } }
    let sent = await inner.upload(saving: saving, deleting: deleting)
    guard !losesNextResult else {
      losesNextResult = false
      throw CKError(.networkFailure)
    }
    return sent
  }

  func accountStatus() async throws -> CKAccountStatus { await inner.accountStatus() }
  func accountName() async throws -> String { await inner.accountName() }
  func relaySecret() async throws -> Data { await inner.relaySecret() }
  func changes(since token: Data?, keys: [String]?) async throws -> ZoneChangeBatch { await inner.changes(since: token, keys: keys) }
  func records(_ ids: [CKRecord.ID]) async throws -> [CKRecord] { await inner.records(ids) }
  func saveZone() async throws {}
  func subscriptions() async throws -> [CKSubscription.ID: CKSubscription] { [:] }
  func save(_ subscription: CKSubscription) async throws {}
  func delete(_ id: CKSubscription.ID) async throws {}
}
