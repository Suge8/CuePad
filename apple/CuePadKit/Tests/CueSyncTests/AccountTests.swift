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
    try await rig.coordinator.reconcile()
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

  /// 账号状态确认之前不能显示成"已同步"。
  @Test func statusIsStartingUntilTheAccountIsConfirmed() async throws {
    #expect(await rig.coordinator.status == .starting)
    await rig.coordinator.handle(.syncing(true))
    #expect(await rig.coordinator.status == .starting)
    await rig.coordinator.handle(.accountStatus(.available))
    #expect(await rig.coordinator.status == .idle)
  }

  @Test func signedOutKeepsLocalDataAndSignedInUploadsItAgain() async throws {
    let card = try await populateAndPush()

    await rig.coordinator.handle(.accountChange(.signedOut))
    #expect(await rig.coordinator.status == .noAccount)
    #expect(try await store.card(card.id)?.body == "mine")  // 本机数据不动

    await rig.coordinator.handle(.accountChange(.signedIn))
    #expect(await rig.coordinator.status == .idle)
    #expect(try await rig.reconcileDelta().saves.contains(rig.id(card.id)))  // 新账号：全部重新上传
  }

  @Test func switchingAccountsStopsSyncingUntilTheUserDecides() async throws {
    let card = try await populateAndPush()
    await rig.coordinator.handle(.stateUpdate(Data("old-account-state".utf8)))

    await rig.coordinator.handle(.accountChange(.switched))
    #expect(await rig.coordinator.status == .needsDecision(.accountSwitched))

    // 决定之前：不登记推送，也不应用新账号的数据
    try await Task.sleep(for: .milliseconds(3))
    try await store.updateCard(card.id) { $0.body = "edited while waiting" }
    #expect(try await rig.reconcileDelta().saves.isEmpty)
    await rig.coordinator.handle(.fetched(modifications: [remoteRecord(.cards, cardFields(project: nil, body: "other user", modifiedAt: 9_000_000_000_000))], deletions: []))
    #expect(try await store.card(card.id)?.body == "edited while waiting")
    #expect(try await store.cards(in: nil).isEmpty)  // 新账号的记录没有被应用
  }

  @Test func uploadingLocalDataAfterASwitchMakesEverythingPendingAgain() async throws {
    let card = try await populateAndPush()
    await rig.coordinator.handle(.stateUpdate(Data("old-account-state".utf8)))
    await rig.coordinator.handle(.accountChange(.switched))

    try await rig.coordinator.resolve(.uploadLocal)

    #expect(await rig.coordinator.status == .idle)
    #expect(try await rig.coordinator.savedEngineState() == nil)  // 旧账号的引擎状态作废
    #expect(try await rig.reconcileDelta().saves.contains(rig.id(card.id)))
  }

  @Test func erasingLocalDataAfterASwitchClearsSyncedTablesOnly() async throws {
    _ = try await populateAndPush()
    let image = try store.files.store(pngData(width: 4, height: 4))
    try await store.upsertPiSession(PiSession(id: "s1", path: "/p", cwd: "/c", lastActivityAt: Date()), host: "mac-a")
    await rig.coordinator.handle(.accountChange(.switched))

    try await rig.coordinator.resolve(.eraseLocal)

    let raw = RawDB(rig.fixture.url)
    for table in ["projects", "cards", "sendRecords", "attachments", "syncRecords"] {
      #expect(try raw.count(table) == 0, "\(table) should be empty")
    }
    #expect(try await store.piSessions().map(\.id) == ["s1"])  // 本机的 Pi 索引与账号无关
    #expect(throws: CueStoreError.notFound) { try store.files.original(hash: image) }
    #expect(await rig.coordinator.status == .idle)
  }

  @Test(arguments: [
    (CloudDataLoss.deleted, SyncDecision.cloudDataDeleted),
    (.purged, .cloudDataReset),
    (.encryptedDataReset, .cloudDataReset),
  ])
  func lostCloudDataAsksTheUserInsteadOfDeciding(loss: CloudDataLoss, expected: SyncDecision) async throws {
    _ = try await populateAndPush()
    await rig.coordinator.handle(.cloudDataLost(loss))
    #expect(await rig.coordinator.status == .needsDecision(expected))
    try await rig.coordinator.resolve(.uploadLocal)
    #expect(await rig.coordinator.status == .idle)
  }

  @Test func resolvingWhenNothingNeedsADecisionIsAnError() async throws {
    await #expect(throws: SyncError.nothingToResolve) { try await rig.coordinator.resolve(.uploadLocal) }
  }

  @Test func quotaExceededIsReportedKeepsChangesPendingAndClearsOnSuccess() async throws {
    let card = try await store.createCard(in: nil, body: "big")
    try await rig.coordinator.reconcile()
    let record = try #require(await rig.coordinator.record(for: rig.recordID(card.id)))

    await rig.coordinator.handle(.sent(saved: [], failedSaves: [(record, CKError(.quotaExceeded))], deleted: [], failedDeletes: []))
    #expect(await rig.coordinator.status == .quotaExceeded)
    #expect(try await rig.reconcileDelta().saves == [rig.id(card.id)])  // 改动仍待推送

    await rig.coordinator.handle(.sent(saved: [record], failedSaves: [], deleted: [], failedDeletes: []))
    #expect(await rig.coordinator.status == .idle)
  }

  @Test func notAuthenticatedFailureMeansNoAccount() async throws {
    let card = try await store.createCard(in: nil, body: "x")
    let record = try #require(await rig.coordinator.record(for: rig.recordID(card.id)))
    await rig.coordinator.handle(.sent(saved: [], failedSaves: [(record, CKError(.notAuthenticated))], deleted: [], failedDeletes: []))
    #expect(await rig.coordinator.status == .noAccount)
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

  @Test func syncingFlagShowsWhileTheEngineIsBusy() async throws {
    await rig.coordinator.handle(.accountStatus(.available))
    await rig.coordinator.handle(.syncing(true))
    #expect(await rig.coordinator.status == .syncing)
    await rig.coordinator.handle(.syncing(false))
    #expect(await rig.coordinator.status == .idle)
  }

  @Test(.timeLimit(.minutes(1)))
  func statusAndIssueChangesAreDeliveredToSubscribers() async throws {
    var updates = rig.coordinator.stateUpdates.makeAsyncIterator()
    #expect(await updates.next() == SyncState(status: .starting, issues: []))  // 订阅时先给出当前状态
    await rig.coordinator.handle(.accountStatus(.noAccount))
    #expect(await updates.next()?.status == .noAccount)

    await rig.coordinator.setAlerts(.failed("没有网络"))
    #expect(await updates.next()?.alerts == .failed("没有网络"))  // 通知订阅的结果与同步状态走同一条流

    // 不改状态的事项与重复的同一失败也要送达：界面据此显示"N 条没能同步的记录"
    let future = CKRecord(recordType: "futureType", recordID: CKRecord.ID(recordName: "x", zoneID: testZone))
    await rig.coordinator.handle(.fetched(modifications: [future], deletions: []))
    let skipped = try #require(await updates.next())
    #expect(skipped.status == .noAccount && skipped.issues.count == 1)
    await rig.coordinator.handle(.accountStatus(.available))
    _ = await updates.next()
    await rig.coordinator.handle(.zoneSaveFailed(CKError(.internalError)))
    let failed = try #require(await updates.next())
    await rig.coordinator.handle(.zoneSaveFailed(CKError(.internalError)))
    let repeated = try #require(await updates.next())
    #expect(repeated.status == failed.status)
    #expect(repeated.issues.count == failed.issues.count + 1)
  }

  @Test func engineStateIsPersistedInTheLocalDatabase() async throws {
    await rig.coordinator.handle(.stateUpdate(Data("state-1".utf8)))
    await rig.coordinator.handle(.stateUpdate(Data("state-2".utf8)))

    let reopened = SyncCoordinator(store: try CueStore(url: rig.fixture.url), queue: rig.queue, zoneID: testZone)
    #expect(try await reopened.savedEngineState() == Data("state-2".utf8))
  }
}
