import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

@Suite struct RemoteApplyTests {
  let rig = try! Rig()
  var store: CueStore { rig.store }

  private func fetched(_ records: CKRecord...) async {
    await rig.coordinator.handle(.fetched(modifications: records, deletions: []))
  }

  /// 本机记录已推送过（服务器有），随后本机再改：返回该卡。
  private func pushedCard(body: String = "base") async throws -> Card {
    let card = try await store.createCard(in: nil, body: body)
    try await rig.coordinator.reconcile()
    try await rig.simulatePush()
    return card
  }

  private func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

  /// 在已推送之后再编辑一次：返回该记录此刻的 modifiedAt（毫秒），用来构造"更新/更旧/同刻"的远端版本。
  private func editCard(_ card: Card, body: String? = nil, pinned: Bool? = nil) async throws -> Int64 {
    try await Task.sleep(for: .milliseconds(3))  // 时间精度是毫秒，确保晚于推送时间
    try await store.updateCard(card.id) {
      if let body { $0.body = body }
      if let pinned { $0.isPinned = pinned }
    }
    return millis(try #require(try await store.card(card.id)).modifiedAt)
  }

  private func editProject(_ id: UUID, name: String) async throws -> Int64 {
    try await Task.sleep(for: .milliseconds(3))
    try await store.updateProject(id) { $0.name = name }
    return millis(try #require(try await store.project(id)).modifiedAt)
  }

  // MARK: 新增、更新、删除

  @Test(.timeLimit(.minutes(1)))
  func remoteRecordsAreInsertedInOneTransactionAndWakeObservers() async throws {
    var values = store.observe { try $0.cards(in: nil).map(\.body) }.makeAsyncIterator()
    #expect(try await values.next() == [])

    let project = remoteRecord(.projects, projectFields(name: "Remote", modifiedAt: 5_000))
    let card = remoteRecord(.cards, cardFields(project: nil, body: "from other device", modifiedAt: 5_000))
    await fetched(project, card)

    #expect(try await values.next() == ["from other device"])
    #expect(try await store.projects().map(\.name) == ["Remote"])
    #expect(try await store.search("other device").cards.count == 1)  // 搜索索引跟随
    let delta = try await rig.reconcileDelta()
    #expect(delta.saves.isEmpty && delta.deletes.isEmpty)  // 刚收到的不会被当成本机改动推回去
  }

  @Test func remoteUpdateOverwritesAnUneditedLocalRecord() async throws {
    let card = try await pushedCard()
    let newer = remoteRecord(.cards, id: card.id, cardFields(project: nil, body: "remote edit", modifiedAt: 9_000_000_000_000))
    await fetched(newer)
    #expect(try await store.card(card.id)?.body == "remote edit")
    #expect(try await rig.reconcileDelta().saves.isEmpty)
  }

  @Test func remoteDeletionRemovesTheRowItsMetadataAndIndexEntry() async throws {
    let card = try await pushedCard(body: "findme")
    await rig.coordinator.handle(.fetched(modifications: [], deletions: [(rig.recordID(card.id), "cards")]))

    #expect(try await store.card(card.id) == nil)
    #expect(try await store.search("findme").cards.isEmpty)
    let delta = try await rig.reconcileDelta()
    #expect(delta.deletes.isEmpty)  // 元数据一并清掉，不会再向服务器发删除
  }

  @Test func remoteDeletionBeatsUnpushedLocalEdits() async throws {
    let card = try await pushedCard()
    _ = try await editCard(card, body: "unpushed")
    await rig.coordinator.handle(.fetched(modifications: [], deletions: [(rig.recordID(card.id), "cards")]))
    #expect(try await store.card(card.id) == nil)
  }

  @Test func localPermanentDeletionIsNotResurrectedByAnIncomingSave() async throws {
    let card = try await pushedCard()
    try await store.purgeCard(card.id)  // 服务器上还有，删除待推送

    await fetched(remoteRecord(.cards, id: card.id, cardFields(project: nil, body: "late", modifiedAt: 9_000_000_000_000)))

    #expect(try await store.card(card.id) == nil)
    #expect(try await rig.reconcileDelta().deletes == [rig.id(card.id)])
  }

  // MARK: 冲突

  @Test func newerLocalEditWinsNonBodyFieldsAndStaysPendingForPush() async throws {
    let project = try await store.createProject(name: "local", color: "#111")
    try await rig.coordinator.reconcile()
    try await rig.simulatePush()
    let local = try await editProject(project.id, name: "local edit")

    await fetched(remoteRecord(.projects, id: project.id, projectFields(name: "remote edit", modifiedAt: local - 1_000)))

    #expect(try await store.project(project.id)?.name == "local edit")
    #expect(try await rig.reconcileDelta().saves == [rig.id(project.id)])  // 仍待推送
  }

  @Test func newerRemoteEditWinsAndTiesGoToTheServer() async throws {
    let project = try await store.createProject(name: "local", color: "#111")
    try await rig.coordinator.reconcile()
    try await rig.simulatePush()
    let local = try await editProject(project.id, name: "local edit")

    await fetched(remoteRecord(.projects, id: project.id, projectFields(name: "remote newer", modifiedAt: local + 1_000)))
    #expect(try await store.project(project.id)?.name == "remote newer")

    let again = try await editProject(project.id, name: "local again")
    await fetched(remoteRecord(.projects, id: project.id, projectFields(name: "remote tie", modifiedAt: again)))
    #expect(try await store.project(project.id)?.name == "remote tie")
    #expect(try await rig.reconcileDelta().saves.isEmpty)
  }

  @Test func concurrentBodyEditsKeepBothVersionsAsAConflictCopy() async throws {
    let card = try await pushedCard(body: "base")
    let local = try await editCard(card, body: "local version")

    await fetched(remoteRecord(.cards, id: card.id, cardFields(project: nil, body: "remote version", modifiedAt: local + 1_000)))

    let conflicts = try await store.conflicts()
    #expect(conflicts.count == 1)
    #expect(conflicts[0].original.id == card.id && conflicts[0].original.body == "remote version")  // 较新的留在原卡
    #expect(conflicts[0].copy.body == "local version" && conflicts[0].copy.conflictOf == card.id)
    #expect(try await store.cards(in: nil).count == 2)  // 副本是一张普通可见的卡，不会悄悄消失
    #expect(try await rig.reconcileDelta().saves == [rig.id(conflicts[0].copy.id)])  // 副本会同步给其他设备
  }

  @Test func localNewerBodyStaysAndTheRemoteVersionBecomesTheCopy() async throws {
    let card = try await pushedCard(body: "base")
    let local = try await editCard(card, body: "local version")

    await fetched(remoteRecord(.cards, id: card.id, cardFields(project: nil, body: "remote version", modifiedAt: local - 1_000)))

    let conflict = try #require(try await store.conflicts().first)
    #expect(conflict.original.body == "local version" && conflict.copy.body == "remote version")
    #expect(try await rig.reconcileDelta().saves.contains(rig.id(card.id)))  // 原卡仍待推送
  }

  @Test func identicalBodiesAreNotAConflict() async throws {
    let card = try await pushedCard(body: "same")
    let local = try await editCard(card, pinned: true)

    await fetched(remoteRecord(.cards, id: card.id, cardFields(project: nil, body: "same", modifiedAt: local + 1_000)))

    #expect(try await store.conflicts().isEmpty)
    #expect(try await store.cards(in: nil).count == 1)
  }

  @Test func resolvingAConflictKeepsTheChosenVersionAndDropsTheOther() async throws {
    for keepCopy in [true, false] {
      let card = try await pushedCard(body: "base")
      let local = try await editCard(card, body: "local")
      await fetched(remoteRecord(.cards, id: card.id, cardFields(project: nil, body: "remote", modifiedAt: local + 1_000)))
      let conflict = try #require(try await store.conflicts().first { $0.original.id == card.id })

      try await store.resolveConflict(copy: conflict.copy.id, keep: keepCopy ? .copy : .original)

      #expect(try await store.card(card.id)?.body == (keepCopy ? "local" : "remote"))
      #expect(try await store.card(conflict.copy.id) == nil)
      #expect(try await store.conflicts().allSatisfy { $0.original.id != card.id })
    }
  }

  @Test func resolvingSomethingThatIsNotAConflictCopyIsRejected() async throws {
    let card = try await store.createCard(in: nil, body: "plain")
    await #expect(throws: CueStoreError.notAConflictCopy) {
      try await store.resolveConflict(copy: card.id, keep: .copy)
    }
  }

  // MARK: 发送结果

  @Test func serverRecordChangedIsMergedLikeAnyRemoteChange() async throws {
    let card = try await pushedCard(body: "base")
    let local = try await editCard(card, pinned: true)
    let client = try #require(await rig.coordinator.record(for: rig.recordID(card.id)))
    let server = remoteRecord(.cards, id: card.id, cardFields(project: nil, body: "base", modifiedAt: local + 1_000))
    let error = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])

    await rig.coordinator.handle(.sent(saved: [], failedSaves: [(client, error)], deleted: [], failedDeletes: []))

    #expect(try await store.card(card.id)?.isPinned == false)  // 服务器版本更新，覆盖本机
    #expect(try await rig.reconcileDelta().saves.isEmpty)
  }

  /// 一批是整体提交的：其中一条被拒，同批没被拒的也以 batchRequestFailed 失败，引擎不会替它们重试。
  /// 它们仍是待推送，必须立刻重新登记；被拒的那条不立刻重试（会空转），等下一次本机改动时对账。
  @Test func recordsThatOnlyFailedBecauseTheirBatchFailedAreQueuedAgain() async throws {
    let rejected = try await store.createCard(in: nil, body: "a")
    let collateral = try await store.createCard(in: nil, body: "b")
    try await rig.coordinator.reconcile()
    let rejectedRecord = try #require(await rig.coordinator.record(for: rig.recordID(rejected.id)))
    let collateralRecord = try #require(await rig.coordinator.record(for: rig.recordID(collateral.id)))
    await rig.queue.clear()

    await rig.coordinator.handle(.sent(
      saved: [], failedSaves: [(rejectedRecord, CKError(.permissionFailure)), (collateralRecord, CKError(.batchRequestFailed))],
      deleted: [], failedDeletes: []))

    #expect(await rig.queue.saves == [rig.id(collateral.id)])
  }

  /// 服务器上的版本更旧、本机版本胜出：记录仍是待推送，要重新登记，否则要等到它下一次被改。
  @Test func aLocalVersionThatWinsAServerConflictIsQueuedAgain() async throws {
    let card = try await pushedCard(body: "base")
    let local = try await editCard(card, pinned: true)
    let client = try #require(await rig.coordinator.record(for: rig.recordID(card.id)))
    let server = remoteRecord(.cards, id: card.id, cardFields(project: nil, body: "base", modifiedAt: local - 1_000))
    await rig.queue.clear()

    await rig.coordinator.handle(.sent(
      saved: [], failedSaves: [(client, CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server]))],
      deleted: [], failedDeletes: []))

    #expect(try await store.card(card.id)?.isPinned == true)
    #expect(await rig.queue.saves == [rig.id(card.id)])
  }

  @Test func unknownItemOnSaveResurrectsTheRecord() async throws {
    let card = try await pushedCard()
    let client = try #require(await rig.coordinator.record(for: rig.recordID(card.id)))

    await rig.coordinator.handle(.sent(saved: [], failedSaves: [(client, CKError(.unknownItem))], deleted: [], failedDeletes: []))

    #expect(try await rig.reconcileDelta().saves == [rig.id(card.id)])  // 忘掉系统字段，重新作为新记录上传
  }

  @Test func confirmedDeletesAndAlreadyGoneRecordsAreForgotten() async throws {
    let one = try await pushedCard()
    let two = try await store.createCard(in: nil, body: "two")
    try await rig.coordinator.reconcile()
    try await rig.simulatePush()
    try await store.purgeCard(one.id)
    try await store.purgeCard(two.id)

    await rig.coordinator.handle(.sent(
      saved: [], failedSaves: [], deleted: [rig.recordID(one.id)],
      failedDeletes: [(rig.recordID(two.id), CKError(.unknownItem))]))

    #expect(try await rig.reconcileDelta().deletes.isEmpty)
  }

  @Test func writeFailuresOtherThanKnownOnesAreReportedNotSwallowed() async throws {
    let card = try await pushedCard()
    let client = try #require(await rig.coordinator.record(for: rig.recordID(card.id)))
    await rig.coordinator.handle(.sent(saved: [], failedSaves: [(client, CKError(.permissionFailure))], deleted: [], failedDeletes: []))

    guard case .failed = await rig.coordinator.status else {
      Issue.record("status should be .failed, got \(await rig.coordinator.status)")
      return
    }
    #expect(!(await rig.coordinator.issues).isEmpty)
  }
}
