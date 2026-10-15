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
    await rig.coordinator.handle(.account("user-a"))
    try await rig.simulatePush()
    return card
  }

  @Test(arguments: [
    (CKAccountStatus.noAccount, SyncStatus.noAccount),
    (.restricted, .accountRestricted),
    (.temporarilyUnavailable, .accountUnavailable),
    (.couldNotDetermine, .accountUnavailable),
  ])
  func accountStatusIsReportedAndRecoversWhenAvailable(status: CKAccountStatus, expected: SyncStatus) async throws {
    await rig.coordinator.handle(.accountStatus(status))
    #expect(await rig.coordinator.status == expected)

    await rig.coordinator.handle(.accountStatus(.available))
    #expect(await rig.coordinator.status == .idle)
  }

  @Test func signingOutKeepsLocalDataAndTheSameAccountCarriesOn() async throws {
    let card = try await populateAndPush()

    await rig.coordinator.handle(.accountStatus(.noAccount))
    #expect(await rig.coordinator.status == .noAccount)
    #expect(try await store.card(card.id)?.body == "mine")  // 本机数据不动

    await rig.coordinator.handle(.accountStatus(.available))
    await rig.coordinator.handle(.account("user-a"))
    #expect(await rig.coordinator.status == .idle)
    #expect(try await rig.reconcileDelta().saves.isEmpty)  // 同一个账号：已推送的不重传
  }

  @Test func switchingAccountsStopsSyncingUntilTheUserDecides() async throws {
    let card = try await populateAndPush()

    await rig.coordinator.handle(.account("user-b"))
    #expect(await rig.coordinator.status == .needsDecision(.accountSwitched))

    // 决定之前：不上传，也不应用新账号的数据
    try await Task.sleep(for: .milliseconds(3))
    try await store.updateCard(card.id) { $0.body = "edited while waiting" }
    #expect(await rig.coordinator.nextBatch(first: [], limit: 400) == nil)
    await rig.coordinator.handle(.fetched(modifications: [remoteRecord(.cards, cardFields(project: nil, body: "other user", modifiedAt: 9_000_000_000_000))], deletions: []))
    #expect(try await store.card(card.id)?.body == "edited while waiting")
    #expect(try await store.cards(in: nil).isEmpty)  // 新账号的记录没有被应用
  }

  @Test func uploadingLocalDataAfterASwitchMakesEverythingPendingForTheNewAccount() async throws {
    let card = try await populateAndPush()
    try await store.setSyncState(ZonePuller.tokenKey, Data("old-token".utf8))
    await rig.coordinator.handle(.account("user-b"))

    try await rig.coordinator.resolve(.uploadLocal)

    #expect(await rig.coordinator.status == .idle)
    #expect(try await store.syncState(ZonePuller.tokenKey) == nil)  // 旧账号的令牌作废
    #expect(try await rig.reconcileDelta().saves.contains(rig.id(card.id)))
    await rig.coordinator.handle(.account("user-b"))
    #expect(await rig.coordinator.status == .idle)  // 新账号记下，不再问
  }

  @Test func erasingLocalDataAfterASwitchClearsSyncedTablesOnly() async throws {
    _ = try await populateAndPush()
    let image = try store.files.store(pngData(width: 4, height: 4))
    try await store.upsertPiSession(IndexedSession(id: "s1", path: "/p", cwd: "/c", lastActivityAt: Date()), host: "mac-a")
    await rig.coordinator.handle(.account("user-b"))

    try await rig.coordinator.resolve(.eraseLocal)

    let raw = RawDB(rig.fixture.url)
    for table in ["projects", "cards", "sendRecords", "attachments", "syncRecords"] {
      #expect(try raw.count(table) == 0, "\(table) should be empty")
    }
    #expect(try await store.piSessions().map(\.id) == ["s1"])  // 本机的 Pi 索引与账号无关
    #expect(throws: CueStoreError.notFound) { try store.files.original(hash: image) }
    #expect(await rig.coordinator.status == .idle)
  }

  @Test(arguments: [(true, SyncDecision.cloudDataDeleted), (false, .cloudDataReset)])
  func lostCloudDataAsksTheUserInsteadOfDeciding(deletedByUser: Bool, expected: SyncDecision) async throws {
    _ = try await populateAndPush()
    await rig.coordinator.handle(.zoneMissing(deletedByUser: deletedByUser))
    #expect(await rig.coordinator.status == .needsDecision(expected))
    try await rig.coordinator.resolve(.uploadLocal)
    #expect(await rig.coordinator.status == .idle)
  }

  /// 第一台设备第一次同步时服务器上还没有同步区：不是云端数据丢了，第一次上传时建区。
  @Test func aMissingZoneBeforeAnythingWasSyncedIsNotADecision() async throws {
    _ = try await store.createCard(in: nil, body: "first")
    await rig.coordinator.handle(.zoneMissing(deletedByUser: false))
    #expect(await rig.coordinator.status != .needsDecision(.cloudDataReset))
    #expect(await rig.coordinator.nextBatch(first: [], limit: 400) != nil)
  }

  @Test func quotaExceededIsReportedKeepsChangesPendingAndClearsOnSuccess() async throws {
    let card = try await store.createCard(in: nil, body: "big")
    let record = try #require(await rig.coordinator.record(for: rig.recordID(card.id)))

    await rig.coordinator.handle(.sent(saved: [], failedSaves: [(record, CKError(.quotaExceeded))], deleted: [], failedDeletes: []))
    #expect(await rig.coordinator.status == .quotaExceeded)
    #expect(try await rig.reconcileDelta().saves == [rig.id(card.id)])  // 改动仍待推送

    await rig.coordinator.handle(.sent(saved: [record], failedSaves: [], deleted: [], failedDeletes: []))
    #expect(await rig.coordinator.status == .idle)
  }

  /// 服务端拒绝某条记录（如同名的旧类型记录不能改类型）：问题带着记录类型、名字与服务端原因，界面才说得清是哪一张。
  @Test func aRejectedRecordIsReportedWithItsTypeNameAndServerReason() async throws {
    let card = try await store.createCard(in: nil, body: "x")
    let record = try #require(await rig.coordinator.record(for: rig.recordID(card.id)))
    let rejection = CKError(
      .invalidArguments, userInfo: ["ServerErrorDescription": "invalid attempt to update record from type 'tasks' to 'cards'"])
    await rig.coordinator.handle(.sent(saved: [], failedSaves: [(record, rejection)], deleted: [], failedDeletes: []))

    let issue = try #require(await rig.coordinator.issues.last)
    #expect(issue.recordType == "cards" && issue.recordName == rig.id(card.id))
    #expect(issue.message.contains("from type 'tasks' to 'cards'"))
  }
}
