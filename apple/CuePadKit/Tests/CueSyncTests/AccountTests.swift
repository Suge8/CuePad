import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

@Suite struct AccountTests {
  let rig = try! Rig()
  var store: CueStore { rig.store }

  private func populateAndPush() async throws -> Card {
    let project = try await store.createProject(name: "P", color: "#111")
    let card = try await store.createCard(in: project.id, body: "mine")
    await rig.coordinator.account("user-a")
    try await rig.simulatePush()
    return card
  }

  @Test func signingOutKeepsLocalDataAndTheSameAccountCarriesOn() async throws {
    let card = try await populateAndPush()

    await rig.coordinator.accountStatus(.noAccount)
    #expect(await rig.coordinator.status == .noAccount)
    #expect(try await store.card(card.id)?.body == "mine")  // 本机数据不动

    await rig.coordinator.accountStatus(.available)
    await rig.coordinator.account("user-a")
    #expect(await rig.coordinator.status == .starting)  // 认了账号还不算已同步：第一次请求成功才是
    #expect(try await rig.reconcileDelta().saves.isEmpty)  // 同一个账号：已推送的不重传
  }

  @Test func switchingAccountsStopsSyncingUntilTheUserDecides() async throws {
    let card = try await populateAndPush()

    await rig.coordinator.account("user-b")
    #expect(await rig.coordinator.status == .needsDecision(.accountSwitched))

    // 决定之前：不上传，也不应用新账号的数据
    try await Task.sleep(for: .milliseconds(3))
    try await store.updateCard(card.id) { $0.body = "edited while waiting" }
    #expect(await rig.coordinator.nextBatch(.pending(excluding: []), limit: 400) == nil)
    let other = remoteRecord(.cards, cardFields(body: "other user", modifiedAt: 9_000_000_000_000))
    await #expect(throws: SyncPaused.self) { try await rig.coordinator.pulled([other], []) }
    #expect(try await store.card(card.id)?.body == "edited while waiting")
    #expect(try await store.cards(in: Project.defaultID).isEmpty)  // 新账号的记录没有被应用
  }

  @Test func uploadingLocalDataAfterASwitchMakesEverythingPendingForTheNewAccount() async throws {
    let card = try await populateAndPush()
    try await store.setSyncState(ZonePuller.tokenKey, Data("old-token".utf8))
    await rig.coordinator.account("user-b")

    try await rig.coordinator.resolve(.uploadLocal)

    #expect(await rig.coordinator.status == .starting)
    #expect(try await store.syncState(ZonePuller.tokenKey) == nil)  // 旧账号的令牌作废
    #expect(try await rig.reconcileDelta().saves.contains(rig.id(card.id)))
    await rig.coordinator.account("user-b")
    #expect(await rig.coordinator.status == .starting)  // 新账号记下，不再问
  }

  @Test func erasingLocalDataAfterASwitchClearsSyncedTablesOnly() async throws {
    _ = try await populateAndPush()
    let image = try store.files.store(pngData(width: 4, height: 4))
    try await store.upsertPiSession(IndexedSession(id: "s1", path: "/p", cwd: "/c", lastActivityAt: Date()), host: "mac-a")
    await rig.coordinator.account("user-b")

    try await rig.coordinator.resolve(.eraseLocal)

    let raw = RawDB(rig.fixture.url)
    for table in ["projects", "cards", "sendRecords", "attachments", "syncRecords"] {
      #expect(try raw.count(table) == 0, "\(table) should be empty")
    }
    #expect(try await store.piSessions().map(\.id) == ["s1"])  // 本机的 Pi 索引与账号无关
    #expect(throws: CueStoreError.notFound) { try store.files.original(hash: image) }
    #expect(await rig.coordinator.status == .starting)
  }

  @Test(arguments: [(true, SyncDecision.cloudDataDeleted), (false, .cloudDataReset)])
  func lostCloudDataAsksTheUserInsteadOfDeciding(deletedByUser: Bool, expected: SyncDecision) async throws {
    _ = try await populateAndPush()
    await rig.coordinator.zoneMissing(deletedByUser: deletedByUser)
    #expect(await rig.coordinator.status == .needsDecision(expected))
    try await rig.coordinator.resolve(.uploadLocal)
    #expect(await rig.coordinator.status == .starting)
  }

  /// 第一台设备第一次同步时服务器上还没有同步区：不是云端数据丢了，第一次上传时建区。
  @Test func aMissingZoneBeforeAnythingWasSyncedIsNotADecision() async throws {
    _ = try await store.createCard(body: "first")
    await rig.coordinator.zoneMissing(deletedByUser: false)
    #expect(await rig.coordinator.status != .needsDecision(.cloudDataReset))
    #expect(await rig.coordinator.nextBatch(.pending(excluding: []), limit: 400) != nil)
  }

  @Test func quotaExceededIsReportedKeepsChangesPendingAndClearsOnSuccess() async throws {
    try await rig.simulatePush()  // 新库的默认项目先传上去
    let card = try await store.createCard(body: "big")
    let record = try #require(await rig.coordinator.record(for: rig.recordID(card.id)))

    _ = await rig.coordinator.sent(SentRecords(saved: [], failedSaves: [(record, CKError(.quotaExceeded))], deleted: [], failedDeletes: []))
    #expect(await rig.coordinator.status == .quotaExceeded)
    #expect(try await rig.reconcileDelta().saves == [rig.id(card.id)])  // 改动仍待推送

    _ = await rig.coordinator.sent(SentRecords(saved: [record], failedSaves: [], deleted: [], failedDeletes: []))
    #expect(await rig.coordinator.status == .idle)
  }

}
