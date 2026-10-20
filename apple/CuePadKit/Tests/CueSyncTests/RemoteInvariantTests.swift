import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

/// 远端变更下的数据不变量。
/// - 项目引用：同步表没有外键，记录乱序到达是常态，所以远端记录里的 projectID 不校验也不改写
///   （否则先到的卡片会被误判为悬空）；卡片与其所属项目分别到达即可。用户入口（创建、移动）的校验在 Store 的本地写路径。
@Suite struct RemoteInvariantTests {
  let rig = try! Rig()
  var store: CueStore { rig.store }

  // MARK: 项目引用不在同步路径上校验

  @Test func cardsArrivingBeforeTheirProjectAreKeptAndAppearOnceTheProjectArrives() async throws {
    let projectID = UUID()
    try await rig.coordinator.pulled([remoteRecord(.cards, cardFields(project: projectID, body: "early", modifiedAt: 5_000))], [])
    #expect(try RawDB(rig.fixture.url).rows("SELECT projectID FROM cards") == [[rig.id(projectID)]])  // 原样保存，没有被改成未分类
    #expect(try await store.cards(in: Project.defaultID).isEmpty)

    try await rig.coordinator.pulled([remoteRecord(.projects, id: projectID, projectFields(name: "late", modifiedAt: 5_000))], [])
    #expect(try await store.cards(in: projectID).map(\.body) == ["early"])
  }

  @Test func cardsOfARemotelyTrashedProjectStayInThatProject() async throws {
    let projectID = UUID()
    var trashed = projectFields(name: "gone", modifiedAt: 5_000)
    trashed["deletedAt"] = .int(5_000)
    try await rig.coordinator.pulled([
      remoteRecord(.projects, id: projectID, trashed),
      remoteRecord(.cards, cardFields(project: projectID, body: "inside", modifiedAt: 5_000)),
    ], [])

    #expect(try await store.cards(in: projectID).isEmpty)  // 随项目隐藏，由项目推导
    #expect(try await store.cards(in: Project.defaultID).isEmpty)
    #expect(try RawDB(rig.fixture.url).rows("SELECT projectID FROM cards") == [[rig.id(projectID)]])
  }

  // MARK: 项目被远端永久删除

  @Test func remotelyPurgedProjectReleasesLocalCardsToTheDefaultProject() async throws {
    let project = try await store.createProject(name: "P", color: "#111")
    try await store.setDirectory("/work/p", for: project.id)
    try await rig.simulatePush()
    // 本机离线期间在该项目下新增的内容（另一台设备的 purge 不知道它们）
    let card = try await store.createCard(in: project.id, body: "written offline")
    let task = try await store.createTask("offline task", in: project.id)

    try await rig.coordinator.pulled([], [(rig.recordID(project.id), "projects")])

    #expect(try await store.project(project.id) == nil)
    #expect(try await store.cards(in: Project.defaultID).map(\.id) == [card.id])  // 内容保留，归入默认项目，而不是悬空隐藏
    #expect(try await store.card(task.id)?.projectID == Project.defaultID)
    #expect(try await store.directory(of: project.id) == nil)
    #expect(try await rig.reconcileDelta().saves == [rig.id(card.id), rig.id(task.id)])  // 归属变更推回去
  }

  @Test func remotelyPurgedProjectDoesNotResurrectCardsTheOtherDeviceAlsoDeleted() async throws {
    let project = try await store.createProject(name: "P", color: "#111")
    let card = try await store.createCard(in: project.id, body: "known to both")
    try await rig.simulatePush()

    try await rig.coordinator.pulled([], [
      (rig.recordID(project.id), "projects"), (rig.recordID(card.id), "cards"),
    ])

    #expect(try await store.card(card.id) == nil)
    #expect(try await rig.reconcileDelta().saves.isEmpty)
  }

  // MARK: 损坏的记录

  @Test func deliveryRequestWithoutAHostIsReportedAsACorruptRecordAndNotApplied() async throws {
    let fields: [String: SQLValue] = [
      "content": .text("x"), "targetKind": .text("piSession"), "targetName": .text("n"), "targetRef": .null,
      "hostID": .null, "mode": .text("send"), "cardID": .null, "status": .text("pending"),
      "resultDetail": .null, "handledBy": .null, "createdAt": .int(1_000), "completedAt": .null, "modifiedAt": .int(1_000),
    ]
    let broken = remoteRecord(.deliveryRequests, fields)

    try await rig.coordinator.pulled([broken], [])

    #expect(try await store.deliveryRequests().isEmpty)
    #expect(try RawDB(rig.fixture.url).count("syncRecords") == 0)
    let issues = await rig.coordinator.issues
    #expect(issues.contains { $0.recordName == broken.recordID.recordName })
  }
}
