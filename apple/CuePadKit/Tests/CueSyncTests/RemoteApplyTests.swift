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
    let card = remoteRecord(.cards, cardFields(body: "from other device", modifiedAt: 5_000))
    try await fetched(project, card)

    #expect(try await values.next() == ["from other device"])
    #expect(Set(try await store.projects().map(\.name)) == ["Remote", "默认"])
    #expect(try await store.search("other device").cards.count == 1)  // 搜索索引跟随
    let delta = try await rig.reconcileDelta()
    #expect(delta.saves.isEmpty && delta.deletes.isEmpty)  // 刚收到的不会被当成本机改动推回去
  }

  /// 别处删掉的记录：行、元数据与搜索索引一起清掉，不再向服务器发删除；本机没推送的编辑也挡不住删除。
  @Test(arguments: [false, true])
  func remoteDeletionRemovesTheRowItsMetadataAndIndexEntry(editedLocally: Bool) async throws {
    let card = try await pushedCard(body: "findme")
    if editedLocally { _ = try await editCard(card, body: "findme unpushed") }
    try await rig.coordinator.pulled([], [(rig.recordID(card.id), "cards")])

    #expect(try await store.card(card.id) == nil)
    #expect(try await store.search("findme").cards.isEmpty)
    #expect(try await rig.reconcileDelta().deletes.isEmpty)
  }

  @Test func localPermanentDeletionIsNotResurrectedByAnIncomingSave() async throws {
    let card = try await pushedCard()
    try await store.purgeCard(card.id)  // 服务器上还有，删除待推送

    try await fetched(remoteRecord(.cards, id: card.id, cardFields(body: "late", modifiedAt: 9_000_000_000_000)))

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

  /// 正文以外的字段按修改时间取新的，同刻归服务器；本机胜出的仍待推送。
  @Test(arguments: [(-1_000, "local edit", true), (1_000, "remote", false), (0, "remote", false)] as [(Int64, String, Bool)])
  func newerEditWinsNonBodyFieldsAndTiesGoToTheServer(remoteOffset: Int64, kept: String, stillPending: Bool) async throws {
    let project = try await store.createProject(name: "local", color: "#111")
    try await rig.simulatePush()
    let local = try await editProject(project.id, name: "local edit")

    try await fetched(remoteRecord(.projects, id: project.id, projectFields(name: "remote", modifiedAt: local + remoteOffset)))

    #expect(try await store.project(project.id)?.name == kept)
    #expect(try await rig.reconcileDelta().saves == (stillPending ? [rig.id(project.id)] : []))
  }

  /// 两边都改了正文：较新的留在原卡，另一版成为一张普通可见的冲突副本，副本与仍待推送的原卡都同步给其他设备。
  @Test(arguments: [true, false])
  func concurrentBodyEditsKeepBothVersionsAsAConflictCopy(remoteIsNewer: Bool) async throws {
    let card = try await pushedCard(body: "base")
    let local = try await editCard(card, body: "local version")

    // 本机较新时：另一台设备在本机上次同步之后、本机编辑之前改的
    try await fetched(remoteRecord(.cards, id: card.id, cardFields(body: "remote version", modifiedAt: local + (remoteIsNewer ? 1_000 : -1))))

    let conflict = try #require(try await store.conflicts().first)
    let (newer, older) = remoteIsNewer ? ("remote version", "local version") : ("local version", "remote version")
    #expect(conflict.original.id == card.id && conflict.original.body == newer)
    #expect(conflict.copy.body == older && conflict.copy.conflictOf == card.id)
    #expect(try await store.cards(in: Project.defaultID).count == 2)
    let pending = try await rig.reconcileDelta().saves
    #expect(pending.contains(rig.id(conflict.copy.id)) && pending.contains(rig.id(card.id)) == !remoteIsNewer)
  }

  @Test func identicalBodiesAreNotAConflict() async throws {
    let card = try await pushedCard(body: "same")
    let local = try await editCard(card, pinned: true)

    try await fetched(remoteRecord(.cards, id: card.id, cardFields(body: "same", modifiedAt: local + 1_000)))

    #expect(try await store.conflicts().isEmpty)
    #expect(try await store.cards(in: Project.defaultID).count == 1)
  }

  /// 留原卡见 App 的 SyncWiringTests；留副本时原卡换成副本的正文，副本消失。
  @Test func keepingTheCopyPutsItsBodyOnTheOriginalAndDropsTheCopy() async throws {
    let card = try await pushedCard(body: "base")
    let local = try await editCard(card, body: "local")
    try await fetched(remoteRecord(.cards, id: card.id, cardFields(body: "remote", modifiedAt: local + 1_000)))
    let conflict = try #require(try await store.conflicts().first)

    try await store.resolveConflict(copy: conflict.copy.id, keep: .copy)

    #expect(try await store.card(card.id)?.body == "local")
    #expect(try await store.card(conflict.copy.id) == nil)
    #expect(try await store.conflicts().isEmpty)
  }

  // MARK: 发送结果

  /// 上传被拒（服务器上有别的版本）：同拉取一样按修改时间合并；服务器的较新就覆盖本机，本机较新就留下、仍待推送。
  @Test(arguments: [true, false])
  func serverRecordChangedIsMergedLikeAnyRemoteChange(serverIsNewer: Bool) async throws {
    let card = try await pushedCard(body: "base")
    let local = try await editCard(card, pinned: true)
    let client = try #require(await rig.coordinator.record(for: rig.recordID(card.id)))
    let server = remoteRecord(.cards, id: card.id, cardFields(body: "base", modifiedAt: local + (serverIsNewer ? 1_000 : -1_000)))
    let error = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])

    _ = await rig.coordinator.sent(SentRecords(saved: [], failedSaves: [(client, error)], deleted: [], failedDeletes: []))

    #expect(try await store.card(card.id)?.isPinned == !serverIsNewer)
    #expect(try await rig.reconcileDelta().saves == (serverIsNewer ? [] : [rig.id(card.id)]))
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
