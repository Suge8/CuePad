import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

@Suite struct RemoteApplyTests {
  let rig = try! Rig()
  var store: CueStore { rig.store }

  private func fetched(_ records: CKRecord...) async throws {
    try await rig.coordinator.pulled(records, [])
  }

  /// 本机记录已推送过（服务器有），随后本机再改：返回该卡。
  private func pushedCard(body: String = "base") async throws -> Card {
    let card = try await store.createCard(body: body)
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
    try await rig.simulatePush()  // 新库的默认项目先传上去
    var values = store.observe { try $0.cards(in: Project.defaultID).map(\.body) }.makeAsyncIterator()
    #expect(try await values.next() == [])

    let project = remoteRecord(.projects, projectFields(name: "Remote", modifiedAt: 5_000))
    let card = remoteRecord(.cards, cardFields(project: nil, body: "from other device", modifiedAt: 5_000))
    try await fetched(project, card)

    #expect(try await values.next() == ["from other device"])
    #expect(try await store.projects().map(\.name) == ["Remote", "默认"])  // 没有项目的卡（更早的版本写的）收进默认项目
    #expect(try await store.search("other device").cards.count == 1)  // 搜索索引跟随
    let delta = try await rig.reconcileDelta()
    #expect(delta.saves.isEmpty && delta.deletes.isEmpty)  // 刚收到的不会被当成本机改动推回去
  }

  @Test func remoteDeletionRemovesTheRowItsMetadataAndIndexEntry() async throws {
    let card = try await pushedCard(body: "findme")
    try await rig.coordinator.pulled([], [(rig.recordID(card.id), "cards")])

    #expect(try await store.card(card.id) == nil)
    #expect(try await store.search("findme").cards.isEmpty)
    let delta = try await rig.reconcileDelta()
    #expect(delta.deletes.isEmpty)  // 元数据一并清掉，不会再向服务器发删除
  }

  @Test func remoteDeletionBeatsUnpushedLocalEdits() async throws {
    let card = try await pushedCard()
    _ = try await editCard(card, body: "unpushed")
    try await rig.coordinator.pulled([], [(rig.recordID(card.id), "cards")])
    #expect(try await store.card(card.id) == nil)
  }

  @Test func localPermanentDeletionIsNotResurrectedByAnIncomingSave() async throws {
    let card = try await pushedCard()
    try await store.purgeCard(card.id)  // 服务器上还有，删除待推送

    try await fetched(remoteRecord(.cards, id: card.id, cardFields(project: nil, body: "late", modifiedAt: 9_000_000_000_000)))

    #expect(try await store.card(card.id) == nil)
    #expect(try await rig.reconcileDelta().deletes == [rig.id(card.id)])
  }

  /// 手机上从灵感开的新会话：Mac 开好后同步来的会话记录带着认领标识，手机这边同一处认领，灵感关联到那个会话。
  @Test func 同步来的会话记录带认领标识_手机上发起的灵感关联到它() async throws {
    let idea = try await store.createCard(body: "看一下重连")
    let project = try await store.createProject(name: "圆桌", color: "#111")
    _ = try await store.requestLaunch(PiLaunch(project: project.id, prompt: idea.body, token: "t-phone"), title: "圆桌", on: "mac-a", card: idea.id)

    let state = remoteRecord(.piSessionStates, id: PiSessionState.recordID(sessionID: "s-new"), [
      "sessionID": .text("s-new"), "hostID": .text("mac-a"), "title": .text("圆桌"), "projectID": .null,
      "state": .text("thinking"), "detail": .null, "stateSince": .int(1_000), "createdAt": .int(1_000),
      "modifiedAt": .int(1_000), "notify": .null, "folder": .null, "lastPrompt": .null, "lastReply": .null,
      "question": .null, "busySince": .null, "launchToken": .text("t-phone"),
    ])
    try await rig.coordinator.pulled([state], [])

    #expect(try await store.card(idea.id)?.piSessionID == "s-new")
  }

  // MARK: 冲突

  @Test func newerLocalEditWinsNonBodyFieldsAndStaysPendingForPush() async throws {
    let project = try await store.createProject(name: "local", color: "#111")
    try await rig.simulatePush()
    let local = try await editProject(project.id, name: "local edit")

    try await fetched(remoteRecord(.projects, id: project.id, projectFields(name: "remote edit", modifiedAt: local - 1_000)))

    #expect(try await store.project(project.id)?.name == "local edit")
    #expect(try await rig.reconcileDelta().saves == [rig.id(project.id)])  // 仍待推送
  }

  @Test func newerRemoteEditWinsAndTiesGoToTheServer() async throws {
    let project = try await store.createProject(name: "local", color: "#111")
    try await rig.simulatePush()
    let local = try await editProject(project.id, name: "local edit")

    try await fetched(remoteRecord(.projects, id: project.id, projectFields(name: "remote newer", modifiedAt: local + 1_000)))
    #expect(try await store.project(project.id)?.name == "remote newer")

    let again = try await editProject(project.id, name: "local again")
    try await fetched(remoteRecord(.projects, id: project.id, projectFields(name: "remote tie", modifiedAt: again)))
    #expect(try await store.project(project.id)?.name == "remote tie")
    #expect(try await rig.reconcileDelta().saves.isEmpty)
  }

  @Test func concurrentBodyEditsKeepBothVersionsAsAConflictCopy() async throws {
    let card = try await pushedCard(body: "base")
    let local = try await editCard(card, body: "local version")

    try await fetched(remoteRecord(.cards, id: card.id, cardFields(project: nil, body: "remote version", modifiedAt: local + 1_000)))

    let conflicts = try await store.conflicts()
    #expect(conflicts.count == 1)
    #expect(conflicts[0].original.id == card.id && conflicts[0].original.body == "remote version")  // 较新的留在原卡
    #expect(conflicts[0].copy.body == "local version" && conflicts[0].copy.conflictOf == card.id)
    #expect(try await store.cards(in: Project.defaultID).count == 2)  // 副本是一张普通可见的卡，不会悄悄消失
    #expect(try await rig.reconcileDelta().saves == [rig.id(conflicts[0].copy.id)])  // 副本会同步给其他设备
  }

  @Test func localNewerBodyStaysAndTheRemoteVersionBecomesTheCopy() async throws {
    let card = try await pushedCard(body: "base")
    let local = try await editCard(card, body: "local version")

    // 另一台设备在本机上次同步之后、本机编辑之前改的
    try await fetched(remoteRecord(.cards, id: card.id, cardFields(project: nil, body: "remote version", modifiedAt: local - 1)))

    let conflict = try #require(try await store.conflicts().first)
    #expect(conflict.original.body == "local version" && conflict.copy.body == "remote version")
    #expect(try await rig.reconcileDelta().saves.contains(rig.id(card.id)))  // 原卡仍待推送
  }

  @Test func identicalBodiesAreNotAConflict() async throws {
    let card = try await pushedCard(body: "same")
    let local = try await editCard(card, pinned: true)

    try await fetched(remoteRecord(.cards, id: card.id, cardFields(project: nil, body: "same", modifiedAt: local + 1_000)))

    #expect(try await store.conflicts().isEmpty)
    #expect(try await store.cards(in: Project.defaultID).count == 1)
  }

  @Test func resolvingAConflictKeepsTheChosenVersionAndDropsTheOther() async throws {
    for keepCopy in [true, false] {
      let card = try await pushedCard(body: "base")
      let local = try await editCard(card, body: "local")
      try await fetched(remoteRecord(.cards, id: card.id, cardFields(project: nil, body: "remote", modifiedAt: local + 1_000)))
      let conflict = try #require(try await store.conflicts().first { $0.original.id == card.id })

      try await store.resolveConflict(copy: conflict.copy.id, keep: keepCopy ? .copy : .original)

      #expect(try await store.card(card.id)?.body == (keepCopy ? "local" : "remote"))
      #expect(try await store.card(conflict.copy.id) == nil)
      #expect(try await store.conflicts().allSatisfy { $0.original.id != card.id })
    }
  }

  // MARK: 发送结果

  @Test func serverRecordChangedIsMergedLikeAnyRemoteChange() async throws {
    let card = try await pushedCard(body: "base")
    let local = try await editCard(card, pinned: true)
    let client = try #require(await rig.coordinator.record(for: rig.recordID(card.id)))
    let server = remoteRecord(.cards, id: card.id, cardFields(project: nil, body: "base", modifiedAt: local + 1_000))
    let error = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])

    _ = await rig.coordinator.sent(SentRecords(saved: [], failedSaves: [(client, error)], deleted: [], failedDeletes: []))

    #expect(try await store.card(card.id)?.isPinned == false)  // 服务器版本更新，覆盖本机
    #expect(try await rig.reconcileDelta().saves.isEmpty)
  }

  /// 服务器上的版本更旧、本机版本胜出：本机版本留下、仍待推送，下一批带着服务器的版本标签重传。
  @Test func aLocalVersionThatWinsAServerConflictStaysPending() async throws {
    let card = try await pushedCard(body: "base")
    let local = try await editCard(card, pinned: true)
    let client = try #require(await rig.coordinator.record(for: rig.recordID(card.id)))
    let server = remoteRecord(.cards, id: card.id, cardFields(project: nil, body: "base", modifiedAt: local - 1_000))

    _ = await rig.coordinator.sent(SentRecords(
      saved: [], failedSaves: [(client, CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server]))],
      deleted: [], failedDeletes: []))

    #expect(try await store.card(card.id)?.isPinned == true)
    #expect(try await rig.reconcileDelta().saves == [rig.id(card.id)])
  }

  @Test func unknownItemOnSaveResurrectsTheRecord() async throws {
    let card = try await pushedCard()
    let client = try #require(await rig.coordinator.record(for: rig.recordID(card.id)))

    _ = await rig.coordinator.sent(SentRecords(saved: [], failedSaves: [(client, CKError(.unknownItem))], deleted: [], failedDeletes: []))

    #expect(try await rig.reconcileDelta().saves == [rig.id(card.id)])  // 忘掉系统字段，重新作为新记录上传
  }

  @Test func confirmedDeletesAndAlreadyGoneRecordsAreForgotten() async throws {
    let one = try await pushedCard()
    let two = try await store.createCard(body: "two")
    try await rig.simulatePush()
    try await store.purgeCard(one.id)
    try await store.purgeCard(two.id)

    _ = await rig.coordinator.sent(SentRecords(
      saved: [], failedSaves: [], deleted: [rig.recordID(one.id)],
      failedDeletes: [(rig.recordID(two.id), CKError(.unknownItem))]))

    #expect(try await rig.reconcileDelta().deletes.isEmpty)
  }

  @Test func writeFailuresOtherThanKnownOnesAreReportedNotSwallowed() async throws {
    let card = try await pushedCard()
    let client = try #require(await rig.coordinator.record(for: rig.recordID(card.id)))
    _ = await rig.coordinator.sent(SentRecords(saved: [], failedSaves: [(client, CKError(.permissionFailure))], deleted: [], failedDeletes: []))
    _ = await rig.coordinator.sent(SentRecords(saved: [], failedSaves: [(client, CKError(.permissionFailure))], deleted: [], failedDeletes: []))  // 停下后重试又报同一个错

    guard case .failed = await rig.coordinator.status else {
      Issue.record("status should be .failed, got \(await rig.coordinator.status)")
      return
    }
    #expect(await rig.coordinator.issues.count == 1)  // 同一个错只进问题列表一次
  }
}
