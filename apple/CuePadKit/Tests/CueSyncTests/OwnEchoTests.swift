import CloudKit
import CueStore
import Testing

@testable import CueSync

/// 用户在一台 Mac 上连续编辑同一条提示词：本机上传过的版本经拉取回到本机时，本机往往已有更新的编辑。
/// 回声不是别的设备的并发编辑，不能留下冲突副本。
@Suite struct OwnEchoTests {
  let rig = try! Rig()
  var store: CueStore { rig.store }

  /// 已同步过的一张卡，随后编辑一次并上传这一版、结果落账：返回卡与上传的记录。
  private func editedAndUploaded(_ body: String) async throws -> (Card, CKRecord) {
    let card = try await store.createCard(body: "base")
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
    #expect(try await store.cards(in: Project.defaultID).map(\.body) == [body])
    #expect(try await rig.reconcileDelta().saves == [rig.id(card.id)])  // 更新的版本仍待推送
  }

  /// 上传已落账，本机又改了、App 也重启过，之后拉取才带回那一版。
  @Test func anUploadedVersionPulledBackAfterItsResultIsNotAConflict() async throws {
    let (card, uploaded) = try await editedAndUploaded("第一版")
    _ = try await edit(card, "第二版")
    let restarted = SyncCoordinator(store: store, zoneID: testZone)

    try await restarted.pulled([uploaded], [])

    try await expectNoCopyAndLocalKept(card, body: "第二版")
  }

  /// 交出去的那一版服务器收下了、结果却没回到本机（崩溃或回包丢失），App 重启、本机又改过；那一版经拉取回来，
  /// 或下一次上传被拒时附回来。
  @Test(arguments: [false, true])
  func anUploadWhoseResultNeverArrivedIsNotAConflict(comesBackAsRejection: Bool) async throws {
    let card = try await store.createCard(body: "base")
    try await rig.simulatePush()
    _ = try await edit(card, "第一版")
    let lost = try #require(await rig.coordinator.nextBatch(first: [], limit: 400)?.saves.first)  // 交出去，结果没回来
    let restarted = SyncCoordinator(store: store, zoneID: testZone)
    _ = try await edit(card, "第二版")

    if comesBackAsRejection {
      let retry = try #require(await restarted.nextBatch(first: [], limit: 400)?.saves.first)
      let rejection = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: lost])
      _ = await restarted.sent(SentRecords(saved: [], failedSaves: [(retry, rejection)], deleted: [], failedDeletes: []))
    } else {
      try await restarted.pulled([lost], [])
    }

    try await expectNoCopyAndLocalKept(card, body: "第二版")
  }

}
