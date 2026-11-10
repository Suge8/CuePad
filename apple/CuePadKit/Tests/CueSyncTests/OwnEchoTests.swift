import CloudKit
import CueStore
import Testing

@testable import CueSync

struct OwnEchoTests {
  let fixture = try! Fixture()
  let cloud = EchoCloud()
  var store: CueStore { fixture.store }

  @Test func anUploadedVersionPulledBackAfterALaterEditIsNotAConflict() async throws {
    let (sync, card) = try await syncedCard()
    try await edit(card, "第一版")
    #expect(await sync.send(recordNames: [name(card)]))

    try await expectEchoIgnored(card, after: sync)
  }

  @Test func anUploadWhoseResultNeverArrivedIsNotAConflict() async throws {
    let (sync, card) = try await syncedCard()
    await cloud.loseResults()
    try await edit(card, "第一版")
    #expect(await !sync.send(recordNames: [name(card)]))

    try await expectEchoIgnored(card, after: sync)
  }

  private func syncedCard() async throws -> (CloudSync, Card) {
    let sync = CloudSync(store: store) { cloud }
    await sync.start()
    try await sync.syncNow()
    let card = try await store.createCard(body: "base")
    #expect(await sync.send(recordNames: [name(card)]))
    return (sync, card)
  }

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
    await nextMillisecond()
    try await store.updateCard(card.id) { $0.body = body }
  }

  private func name(_ card: Card) -> String { card.id.uuidString.lowercased() }
}

actor EchoCloud: SyncCloud {
  private let inner: SimulatedCloud
  private var holding = false
  private var held: [CheckedContinuation<Void, Never>] = []
  private var losesResults = false

  init() {
    let floor = CKRecord(recordType: PeerFloor.recordType, recordID: PeerFloor(zoneID: CloudSync.zoneID).id)
    floor[PeerFloor.field] = CueStore.peerFloor as NSNumber
    inner = SimulatedCloud([floor])
  }

  func hold() { holding = true }

  func release() {
    holding = false
    held.forEach { $0.resume() }
    held = []
  }

  /// 之后的上传都到了服务器、结果都回不来。不是只丢下一次：编辑后后台那一路过了攒批窗口也会发这一版，丢的若是它的，
  /// 马上传再发时服务器已有这一版、答收下了。
  func loseResults() { losesResults = true }

  func upload(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> SentRecords {
    if holding { await withCheckedContinuation { held.append($0) } }
    let sent = await inner.upload(saving: saving, deleting: deleting)
    if losesResults { throw CKError(.networkFailure) }
    return sent
  }

  func accountStatus() async throws -> CKAccountStatus { await inner.accountStatus() }
  func accountName() async throws -> String { await inner.accountName() }
  func relaySecret() async throws -> Data { await inner.relaySecret() }
  func diagnosticChanges(since token: Data?) async throws -> ZoneChangeBatch { try await inner.diagnosticChanges(since: token) }
  func uploadDiagnostics(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> SentRecords {
    await inner.uploadDiagnostics(saving: saving, deleting: deleting)
  }
  func changes(since token: Data?, keys: [String]) async throws -> ZoneChangeBatch { await inner.changes(since: token, keys: keys) }
  func records(_ ids: [CKRecord.ID]) async throws -> [CKRecord] { await inner.records(ids) }
  func uploadFile(_ record: CKRecord, progress: @escaping @Sendable (Double) -> Void) async throws -> SentRecords {
    try await upload(saving: [record], deleting: [])
  }
  func resumedFileUploads() async throws -> [ResumedUpload] { [] }
  func downloadFile(_ id: CKRecord.ID, progress: @escaping @Sendable (Double) -> Void) async throws -> CKRecord? {
    await inner.downloadFile(id, progress: progress)
  }
  func saveZone() async throws {}
  func subscriptions() async throws -> [CKSubscription.ID: CKSubscription] { [:] }
  func save(_ subscription: CKSubscription) async throws {}
  func delete(_ id: CKSubscription.ID) async throws {}
}
