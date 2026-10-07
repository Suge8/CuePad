import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

/// 远端变更下的任务层级不变量：两台设备离线并发地挪任务，合并后可能出现环、超过三级、子任务与父任务不在同一项目。
/// 应用远端变更后按确定的规则收敛（各设备算出同一结果），修正写回并推送：
/// 环里 id 最小的那条回到顶层；挂在第三级下的提到第三级（挂到第二级上）；子任务跟随父任务的项目。
/// 父任务还没到（乱序）的不动。
@Suite struct RemoteTaskTreeTests {
  let rig = try! Rig()
  var store: CueStore { rig.store }

  private func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

  private func remote(_ task: Card, parent: UUID?, project: UUID? = nil, later: Int64 = 1_000) -> CKRecord {
    var fields = cardFields(project: project ?? task.projectID, body: task.body, modifiedAt: millis(task.modifiedAt) + later, sortKey: task.sortKey)
    fields["parentID"] = parent.map { .text($0.uuidString.lowercased()) } ?? .null
    fields["todoAt"] = .int(1_000)
    return remoteRecord(.cards, id: task.id, fields)
  }

  private func pushed() async throws {
    try await rig.coordinator.reconcile()
    try await rig.simulatePush()
  }

  @Test func 两台设备互相挂成环_环里id最小的回到顶层_修正被推送() async throws {
    let a = try await store.createTask("a", in: nil)
    let b = try await store.createTask("b", in: nil)
    try await pushed()
    try await store.moveCard(a.id, to: .under(b.id), after: nil)
    let movedB = try #require(try await store.card(b.id))

    await rig.coordinator.handle(.fetched(modifications: [remote(movedB, parent: a.id)], deletions: []))

    let first = [a.id, b.id].min { $0.uuidString.lowercased() < $1.uuidString.lowercased() }!
    let other = first == a.id ? b.id : a.id
    #expect(try await store.card(first)?.parentID == nil)
    #expect(try await store.card(other)?.parentID == first)
    #expect(try await rig.reconcileDelta().saves.contains(rig.id(first)))
  }

  @Test func 并发挪出第四级_提到第三级() async throws {
    let a = try await store.createTask("a", in: nil)
    let a1 = try await store.createTask("a1", under: a.id)
    let a2 = try await store.createTask("a2", under: a1.id)
    let b = try await store.createTask("b", in: nil)
    let b1 = try await store.createTask("b1", under: b.id)
    try await pushed()

    await rig.coordinator.handle(.fetched(modifications: [remote(b, parent: a2.id)], deletions: []))

    #expect(try await store.card(b.id)?.parentID == a1.id)
    #expect(try await store.card(b1.id)?.parentID == a1.id)
  }

  @Test func 父任务在别处换了项目_子任务跟过去_父任务还没到的不动() async throws {
    let site = try await store.createProject(name: "网站", color: "#111")
    let table = try await store.createProject(name: "圆桌", color: "#111")
    let parent = try await store.createTask("上线", in: site.id)
    let child = try await store.createTask("备份", under: parent.id)
    try await pushed()

    var fields = cardFields(project: nil, body: "父任务还在路上", modifiedAt: 2_000)
    fields["parentID"] = .text(UUID().uuidString.lowercased())
    fields["todoAt"] = .int(1_000)
    let orphan = remoteRecord(.cards, fields)
    await rig.coordinator.handle(.fetched(modifications: [remote(parent, parent: nil, project: table.id), orphan], deletions: []))

    #expect(try await store.card(child.id)?.projectID == table.id)
    let waiting = try #require(try await store.tasks(.todo).flatMap(\.tasks).first { $0.body == "父任务还在路上" })
    #expect(waiting.parentID != nil)
  }
}
