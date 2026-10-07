import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

/// 合并后的同步：服务器上留着的旧 tasks 记录（退役类型，未升级的设备还会写）一律跳过、不报问题；
/// 远端把某张卡挂到了一个已不再"要做"的灵感下（别处并发取消了要做），按"只有任务能当上级"收敛：提到那个灵感的位置。
@Suite struct UnifiedSyncTests {
  let rig = try! Rig()
  var store: CueStore { rig.store }

  @Test func 退役的tasks记录跳过且不报问题() async throws {
    let old = CKRecord(recordType: "tasks", recordID: CKRecord.ID(recordName: UUID().uuidString.lowercased(), zoneID: testZone))
    old.encryptedValues["content"] = "旧设备写的任务"
    await rig.coordinator.handle(.fetched(modifications: [old], deletions: [(old.recordID, "tasks")]))
    #expect(await rig.coordinator.issues.isEmpty)
    #expect(try await store.tasks(.todo).isEmpty)
  }

  @Test func 远端挂到灵感下的卡片提到那个灵感的位置() async throws {
    let top = try await store.createTask("上线", in: nil)
    let idea = try await store.createCard(in: nil, body: "灵感")
    try await rig.coordinator.reconcile()
    try await rig.simulatePush()
    let sub = try await store.createTask("备份", under: top.id)
    try await rig.coordinator.reconcile()
    try await rig.simulatePush()

    var fields = cardFields(project: nil, body: "备份", modifiedAt: Int64((Date.now.timeIntervalSince1970 * 1000).rounded()) + 5_000)
    fields["parentID"] = .text(idea.id.uuidString.lowercased())
    fields["todoAt"] = .int(1_000)
    await rig.coordinator.handle(.fetched(modifications: [remoteRecord(.cards, id: sub.id, fields)], deletions: []))

    #expect(try await store.card(sub.id)?.parentID == nil)
  }
}
