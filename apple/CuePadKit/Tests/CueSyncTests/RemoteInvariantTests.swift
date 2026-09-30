import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

/// 远端变更下的数据不变量。
/// - 项目目标卡：不得指向已回收、已删除或已不属于该项目的卡（离线并发时可能出现，同步后必须收敛）。
/// - 项目引用：同步表没有外键，记录乱序到达是常态，所以远端记录里的 projectID 不校验也不改写
///   （否则先到的卡片会被误判为悬空）；卡片与其所属项目分别到达即可。用户入口（创建、移动）的校验在 Store 的本地写路径。
@Suite struct RemoteInvariantTests {
  let rig = try! Rig()
  var store: CueStore { rig.store }

  private func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

  /// 项目里有目标卡，且都已推送。
  private func projectWithGoal() async throws -> (project: Project, goal: Card) {
    let project = try await store.createProject(name: "P", color: "#111")
    let goal = try await store.createCard(in: project.id, body: "goal")
    try await store.setGoal(goal.id, for: project.id)
    try await rig.coordinator.reconcile()
    try await rig.simulatePush()
    return (project, goal)
  }

  private func goal(of project: Project) async throws -> UUID? { try await store.project(project.id)?.goalCardID }

  private func trashedRemotely(_ card: Card, in project: Project) async throws -> CKRecord {
    var fields = cardFields(project: project.id, body: card.body, modifiedAt: millis(card.modifiedAt) + 1_000)
    fields["deletedAt"] = .int(millis(card.modifiedAt) + 1_000)
    return remoteRecord(.cards, id: card.id, fields)
  }

  @Test func goalIsClearedWhenItsCardIsTrashedRemotelyAndTheClearingIsPushed() async throws {
    let (project, goalCard) = try await projectWithGoal()

    await rig.coordinator.handle(.fetched(modifications: [try await trashedRemotely(goalCard, in: project)], deletions: []))

    #expect(try await goal(of: project) == nil)
    #expect(try await rig.reconcileDelta().saves == [rig.id(project.id)])  // 其他设备也要收敛到"没有目标"
  }

  @Test func goalIsClearedWhenItsCardIsDeletedRemotely() async throws {
    let (project, goalCard) = try await projectWithGoal()
    await rig.coordinator.handle(.fetched(modifications: [], deletions: [(rig.recordID(goalCard.id), "cards")]))
    #expect(try await goal(of: project) == nil)
  }

  @Test func goalIsClearedWhenItsCardWasMovedToAnotherProjectRemotely() async throws {
    let (project, goalCard) = try await projectWithGoal()
    let other = try await store.createProject(name: "other", color: "#222")
    let moved = remoteRecord(.cards, id: goalCard.id, cardFields(project: other.id, body: "goal", modifiedAt: millis(goalCard.modifiedAt) + 1_000))
    await rig.coordinator.handle(.fetched(modifications: [moved], deletions: []))
    #expect(try await goal(of: project) == nil)
  }

  @Test func aNewerLocalProjectEditCannotKeepAGoalWhoseCardIsAlreadyTrashed() async throws {
    let (project, goalCard) = try await projectWithGoal()
    try await Task.sleep(for: .milliseconds(3))
    try await store.updateProject(project.id) { $0.name = "renamed offline" }  // 本机未推送的较新改动，目标卡仍指向原卡
    let local = millis(try #require(try await store.project(project.id)).modifiedAt)

    await rig.coordinator.handle(.fetched(modifications: [try await trashedRemotely(goalCard, in: project)], deletions: []))
    #expect(try await goal(of: project) == nil)
    #expect(try await store.project(project.id)?.name == "renamed offline")
    #expect(try await store.project(project.id).map { millis($0.modifiedAt) }! >= local)
  }

  @Test func remoteProjectRecordPointingAtAnAlreadyTrashedCardIsCorrected() async throws {
    let (project, goalCard) = try await projectWithGoal()
    try await store.trashCard(goalCard.id)  // 本机已回收（目标随之清空）
    try await rig.coordinator.reconcile()
    try await rig.simulatePush()
    var fields = projectFields(name: "P", modifiedAt: 9_000_000_000_000)
    fields["goalCardID"] = .text(rig.id(goalCard.id))  // 另一台设备较新的项目版本仍指向它

    await rig.coordinator.handle(.fetched(modifications: [remoteRecord(.projects, id: project.id, fields)], deletions: []))

    #expect(try await goal(of: project) == nil)
  }

  @Test func goalPointingAtACardThatHasNotArrivedYetIsKept() async throws {
    let project = try await store.createProject(name: "P", color: "#111")
    try await rig.coordinator.reconcile()
    try await rig.simulatePush()
    let cardID = UUID()
    var fields = projectFields(name: "P", modifiedAt: 9_000_000_000_000)
    fields["goalCardID"] = .text(rig.id(cardID))
    await rig.coordinator.handle(.fetched(modifications: [remoteRecord(.projects, id: project.id, fields)], deletions: []))
    #expect(try await goal(of: project) == cardID)  // 乱序：卡片稍后到达，不能提前清掉

    await rig.coordinator.handle(.fetched(modifications: [remoteRecord(.cards, id: cardID, cardFields(project: project.id, body: "late", modifiedAt: 9_000_000_000_001))], deletions: []))
    #expect(try await goal(of: project) == cardID)
    #expect(try await store.cards(in: project.id).map(\.id) == [cardID])
  }

  // MARK: 项目引用不在同步路径上校验

  @Test func cardsArrivingBeforeTheirProjectAreKeptAndAppearOnceTheProjectArrives() async throws {
    let projectID = UUID()
    await rig.coordinator.handle(.fetched(modifications: [remoteRecord(.cards, cardFields(project: projectID, body: "early", modifiedAt: 5_000))], deletions: []))
    #expect(try RawDB(rig.fixture.url).rows("SELECT projectID FROM cards") == [[rig.id(projectID)]])  // 原样保存，没有被改成未归档
    #expect(try await store.cards(in: nil).isEmpty)

    await rig.coordinator.handle(.fetched(modifications: [remoteRecord(.projects, id: projectID, projectFields(name: "late", modifiedAt: 5_000))], deletions: []))
    #expect(try await store.cards(in: projectID).map(\.body) == ["early"])
  }

  @Test func cardsOfARemotelyTrashedProjectStayInThatProject() async throws {
    let projectID = UUID()
    var trashed = projectFields(name: "gone", modifiedAt: 5_000)
    trashed["deletedAt"] = .int(5_000)
    await rig.coordinator.handle(.fetched(modifications: [
      remoteRecord(.projects, id: projectID, trashed),
      remoteRecord(.cards, cardFields(project: projectID, body: "inside", modifiedAt: 5_000)),
    ], deletions: []))

    #expect(try await store.cards(in: projectID).isEmpty)  // 随项目隐藏，由项目推导
    #expect(try await store.cards(in: nil).isEmpty)
    #expect(try RawDB(rig.fixture.url).rows("SELECT projectID FROM cards") == [[rig.id(projectID)]])
  }

  // MARK: 项目被远端永久删除

  @Test func remotelyPurgedProjectReleasesLocalCardsAndTasksToInboxAndGlobal() async throws {
    let project = try await store.createProject(name: "P", color: "#111")
    try await store.setDirectory("/work/p", for: project.id)
    try await rig.coordinator.reconcile()
    try await rig.simulatePush()
    // 本机离线期间在该项目下新增的内容（另一台设备的 purge 不知道它们）
    let card = try await store.createCard(in: project.id, body: "written offline")
    let task = try await store.createTask("offline task", in: project.id)

    await rig.coordinator.handle(.fetched(modifications: [], deletions: [(rig.recordID(project.id), "projects")]))

    #expect(try await store.project(project.id) == nil)
    #expect(try await store.cards(in: nil).map(\.id) == [card.id])  // 内容保留，归入未归档，而不是悬空隐藏
    #expect(try await store.tasks().first { $0.id == task.id }?.projectID == nil)
    #expect(try await store.directory(of: project.id) == nil)
    #expect(try await rig.reconcileDelta().saves == [rig.id(card.id), rig.id(task.id)])  // 归属变更推回去
  }

  @Test func remotelyPurgedProjectDoesNotResurrectCardsTheOtherDeviceAlsoDeleted() async throws {
    let project = try await store.createProject(name: "P", color: "#111")
    let card = try await store.createCard(in: project.id, body: "known to both")
    try await rig.coordinator.reconcile()
    try await rig.simulatePush()

    await rig.coordinator.handle(.fetched(modifications: [], deletions: [
      (rig.recordID(project.id), "projects"), (rig.recordID(card.id), "cards"),
    ]))

    #expect(try await store.card(card.id) == nil)
    #expect(try await rig.reconcileDelta().saves.isEmpty)
  }

  // MARK: 损坏的记录

  @Test func deliveryRequestWithoutAHostIsReportedAsACorruptRecordAndNotApplied() async throws {
    let fields: [String: SQLValue] = [
      "content": .text("x"), "targetKind": .text("piSession"), "targetName": .text("n"), "targetRef": .null,
      "hostID": .null, "mode": .text("send"), "cardID": .null, "taskID": .null, "status": .text("pending"),
      "resultDetail": .null, "handledBy": .null, "createdAt": .int(1_000), "completedAt": .null, "modifiedAt": .int(1_000),
    ]
    let broken = remoteRecord(.deliveryRequests, fields)

    await rig.coordinator.handle(.fetched(modifications: [broken], deletions: []))

    #expect(try await store.deliveryRequests().isEmpty)
    #expect(try RawDB(rig.fixture.url).count("syncRecords") == 0)
    let issues = await rig.coordinator.issues
    #expect(issues.contains { $0.recordName == broken.recordID.recordName })
  }
}
