import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

/// 用户在一台 Mac 上连续编辑同一条提示词：本机上传过的版本经拉取回到本机时，本机往往已有更新的编辑。
/// 回声不是别的设备的并发编辑，不能留下冲突副本。上传一次只有一批在路上、结果先于之后的拉取落账，所以回声都按推送时间认。
@Suite struct OwnEchoTests {
  let rig = try! Rig()
  var store: CueStore { rig.store }

  /// 已同步过的一张卡，随后编辑一次并上传这一版、结果落账：返回卡与上传的记录。
  private func editedAndUploaded(_ body: String) async throws -> (Card, CKRecord) {
    let card = try await store.createCard(in: nil, body: "base")
    try await rig.simulatePush()
    _ = try await edit(card, body)
    return (card, try #require(try await rig.simulatePush().first))
  }

  private func edit(_ card: Card, _ body: String) async throws -> CKRecord {
    try await Task.sleep(for: .milliseconds(3))  // 修改时间是毫秒，每一版要落在不同的毫秒
    try await store.updateCard(card.id) { $0.body = body }
    return try #require(await rig.coordinator.record(for: rig.recordID(card.id)))
  }

  private func expectNoCopyAndLocalKept(_ card: Card, body: String) async throws {
    #expect(try await store.conflicts().isEmpty)
    #expect(try await store.cards(in: nil).map(\.body) == [body])
    #expect(try await rig.reconcileDelta().saves == [rig.id(card.id)])  // 更新的版本仍待推送
  }

  /// 上传已落账，本机又改了、App 也重启过，之后拉取才带回那一版。
  @Test func anUploadedVersionPulledBackAfterItsResultIsNotAConflict() async throws {
    let (card, uploaded) = try await editedAndUploaded("第一版")
    _ = try await edit(card, "第二版")
    let restarted = SyncCoordinator(store: store, zoneID: testZone)

    await restarted.handle(.fetched(modifications: [uploaded], deletions: []))

    try await expectNoCopyAndLocalKept(card, body: "第二版")
  }

  /// 另一台设备离线并发编辑仍保留冲突副本。
  @Test func anotherDevicesConcurrentEditStillKeepsBothVersions() async throws {
    let (card, _) = try await editedAndUploaded("第一版")
    let local = try await edit(card, "本机第二版")
    let other = remoteRecord(.cards, id: card.id, cardFields(project: nil, body: "另一台的版本", modifiedAt: (local["modifiedAt"] as! NSNumber).int64Value + 1_000))

    await rig.coordinator.handle(.fetched(modifications: [other], deletions: []))

    let conflict = try #require(try await store.conflicts().first)
    #expect(conflict.original.body == "另一台的版本" && conflict.copy.body == "本机第二版")
  }
}
