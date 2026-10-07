import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

/// 待推送登记：由数据库状态推导（新记录、编辑后的记录、已删除但服务器还有的记录），不依赖墓碑表。
@Suite struct PendingTests {
  let rig = try! Rig()
  var store: CueStore { rig.store }

  @Test func newRecordsAreEnqueuedOnceAndQuietAfterThePushSucceeds() async throws {
    let project = try await store.createProject(name: "P", color: "#111")
    let card = try await store.createCard(in: project.id, body: "x")

    let first = try await rig.reconcileDelta()
    #expect(first.saves == [rig.id(project.id), rig.id(card.id)] && first.deletes.isEmpty)

    try await rig.simulatePush()
    let second = try await rig.reconcileDelta()
    #expect(second.saves.isEmpty && second.deletes.isEmpty)
  }

  @Test func editAfterPushEnqueuesOnlyThatRecord() async throws {
    let project = try await store.createProject(name: "P", color: "#111")
    let card = try await store.createCard(in: project.id, body: "x")
    try await rig.coordinator.reconcile()
    try await rig.simulatePush()

    try await Task.sleep(for: .milliseconds(3))  // 时间精度是毫秒
    try await store.updateCard(card.id) { $0.body = "edited" }

    let delta = try await rig.reconcileDelta()
    #expect(delta.saves == [rig.id(card.id)])
  }

  /// "待推送"只有一个定义：单条判定（失败后决定要不要重新登记）与全量对账认同一批记录。
  @Test func theSingleRecordCheckAgreesWithTheFullReconcile() async throws {
    let clean = try await store.createCard(in: nil, body: "clean")
    let edited = try await store.createCard(in: nil, body: "edited")
    try await rig.coordinator.reconcile()
    try await rig.simulatePush()
    try await Task.sleep(for: .milliseconds(3))  // 时间精度是毫秒
    try await store.updateCard(edited.id) { $0.body = "edited again" }
    let neverPushed = try await store.createCard(in: nil, body: "new")

    let batch = Set(try await store.pendingSync().saves.map(\.id))
    #expect(batch == [rig.id(edited.id), rig.id(neverPushed.id)])
    for card in [clean, edited, neverPushed] {
      #expect(try await store.isPending(rig.id(card.id)) == batch.contains(rig.id(card.id)))
    }
    #expect(try await store.isPending("no-such-record") == false)
  }

  @Test func permanentDeletionEnqueuesDeletesWithoutATombstoneTable() async throws {
    let project = try await store.createProject(name: "P", color: "#111")
    let card = try await store.createCard(in: project.id, body: "x")
    let send = try await store.recordSend("s", to: SendTarget(kind: .clipboard, name: "c"), card: card.id)
    try await rig.coordinator.reconcile()
    try await rig.simulatePush()

    try await Task.sleep(for: .milliseconds(3))
    try await store.purgeCard(card.id)

    let delta = try await rig.reconcileDelta()
    #expect(delta.deletes == [rig.id(card.id)])  // 项目仍在
    #expect(delta.saves == [rig.id(send.id)])  // 发送记录的 cardID 被清空，是一次普通修改
    #expect(try RawDB(rig.fixture.url).rows("SELECT name FROM sqlite_master WHERE type='table' AND lower(name) LIKE '%tomb%'").isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func localWritesAreRegisteredAutomaticallyOnceStarted() async throws {
    try await rig.coordinator.start()
    let card = try await store.createCard(in: nil, body: "auto")
    let id = rig.id(card.id)
    await rig.queue.waitUntil { saves, _ in saves.contains(id) }

    try await rig.simulatePush()
    try await store.purgeCard(card.id)
    await rig.queue.waitUntil { _, deletes in deletes.contains(id) }
    await rig.coordinator.stop()
  }

  /// 开始同步后，每次本机写入只登记这次改动的记录（由提交时记下的改动行得出），不再全表对账。
  @Test(.timeLimit(.minutes(1)))
  func eachLocalWriteRegistersOnlyTheRecordsItChanged() async throws {
    let untouched = rig.id(try await store.createCard(in: nil, body: "没推送、之后也没再改").id)
    let edited = try await store.createCard(in: nil, body: "v1")
    try await rig.coordinator.start()  // 启动时全量对账一次
    await rig.queue.waitUntil { saves, _ in saves.contains(untouched) }
    await rig.queue.clear()

    try await Task.sleep(for: .milliseconds(3))
    try await store.updateCard(edited.id) { $0.body = "v2" }
    let marker = rig.id(try await store.createCard(in: nil, body: "之后的一次写入").id)
    await rig.queue.waitUntil { saves, _ in saves.contains(marker) }

    #expect(await rig.queue.saves.sorted() == [rig.id(edited.id), marker].sorted())
    await rig.coordinator.stop()
  }

  /// 引擎发送旧版本期间记录又改了：发送成功后它仍待推送，要重新登记（引擎已移除这条待办）。
  @Test(.timeLimit(.minutes(1)))
  func editMadeWhileThePreviousVersionWasSendingIsRegisteredAgain() async throws {
    try await rig.coordinator.start()
    let card = try await store.createCard(in: nil, body: "v1")
    let id = rig.id(card.id)
    await rig.queue.waitUntil { saves, _ in saves.contains(id) }
    let sending = try #require(await rig.coordinator.record(for: rig.recordID(card.id)))

    try await Task.sleep(for: .milliseconds(3))
    try await store.updateCard(card.id) { $0.body = "v2" }
    await rig.queue.waitUntil { saves, _ in saves.count == 2 }
    await rig.queue.clear()
    await rig.coordinator.handle(.sent(saved: [sending], failedSaves: [], deleted: [], failedDeletes: []))

    await rig.queue.waitUntil { saves, _ in saves.contains(id) }
    await rig.coordinator.stop()
  }

  @Test func recordProviderBuildsFromCurrentRowAndReturnsNilForDeletedOnes() async throws {
    let card = try await store.createCard(in: nil, body: "now")
    let record = try #require(await rig.coordinator.record(for: rig.recordID(card.id)))
    #expect(record.encryptedValues["body"] as? String == "now")

    try await store.purgeCard(card.id)
    #expect(await rig.coordinator.record(for: rig.recordID(card.id)) == nil)
  }

  @Test func zoneIsRequestedWhenStarting() async throws {
    try await rig.coordinator.start()
    #expect(await rig.queue.zoneRequests >= 1)
    await rig.coordinator.stop()
  }
}
