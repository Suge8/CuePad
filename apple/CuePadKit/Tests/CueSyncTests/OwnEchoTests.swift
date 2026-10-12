import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

/// 用户在一台 Mac 上连续编辑同一条提示词：本机上传过的版本经主动拉取或引擎拉取回到本机时，
/// 本机往往已有更新的编辑。回声不是别的设备的并发编辑，不能留下冲突副本。
@Suite struct OwnEchoTests {
  let rig = try! Rig()
  var store: CueStore { rig.store }

  private func batch(_ token: String, _ records: [CKRecord] = []) -> Result<ZoneChangeBatch, any Error> {
    .success(ZoneChangeBatch(modifications: records, deletions: [], token: Data(token.utf8), moreComing: false))
  }

  /// 已同步过的一张卡，随后编辑一次并由引擎取走这一版上传：返回卡与上传的记录。
  private func editedAndHandedToTheEngine(_ body: String) async throws -> (Card, CKRecord) {
    let card = try await store.createCard(in: nil, body: "base")
    try await rig.coordinator.reconcile()
    try await rig.simulatePush()
    return (card, try await edit(card, body))
  }

  private func edit(_ card: Card, _ body: String) async throws -> CKRecord {
    try await Task.sleep(for: .milliseconds(3))  // 修改时间是毫秒，每一版要落在不同的毫秒
    try await store.updateCard(card.id) { $0.body = body }
    return try #require(await rig.coordinator.record(for: rig.recordID(card.id)))
  }

  /// 主动拉取（2 秒一次）从服务器拉到一批变化。
  private func pull(_ records: [CKRecord]) async throws {
    let puller = ZoneChangePuller(source: FakeZone([batch("t1"), batch("t2", records)]), coordinator: rig.coordinator)
    try await puller.pull()
  }

  private func expectNoCopyAndLocalKept(_ card: Card, body: String) async throws {
    #expect(try await store.conflicts().isEmpty)
    #expect(try await store.cards(in: nil).map(\.body) == [body])
    #expect(try await rig.reconcileDelta().saves == [rig.id(card.id)])  // 更新的版本仍待推送
  }

  /// 上传还没落账，拉取先到。
  @Test func anUploadedVersionPulledBackBeforeItsResultIsNotAConflict() async throws {
    let (card, uploaded) = try await editedAndHandedToTheEngine("第一版")
    _ = try await edit(card, "第二版")

    try await pull([uploaded])

    try await expectNoCopyAndLocalKept(card, body: "第二版")
  }

  /// 上传已落账，本机又改了，之后拉取才到。
  @Test func anUploadedVersionPulledBackAfterItsResultIsNotAConflict() async throws {
    let (card, uploaded) = try await editedAndHandedToTheEngine("第一版")
    await rig.coordinator.handle(.sent(saved: [uploaded], failedSaves: [], deleted: [], failedDeletes: []))
    _ = try await edit(card, "第二版")

    try await pull([uploaded])

    try await expectNoCopyAndLocalKept(card, body: "第二版")
  }

  /// 连续几版都已上传，较早一版的回声在较晚一版落账之后才到。
  @Test func anEarlierUploadedVersionPulledBackLateIsNotAConflict() async throws {
    let (card, first) = try await editedAndHandedToTheEngine("第一版")
    let second = try await edit(card, "第二版")
    await rig.coordinator.handle(.sent(saved: [first, second], failedSaves: [], deleted: [], failedDeletes: []))
    _ = try await edit(card, "第三版")

    try await pull([first])

    try await expectNoCopyAndLocalKept(card, body: "第三版")
  }

  /// 上传其实成功了但结果丢了（超时），引擎重传时被服务器以 serverRecordChanged 拒绝，附上的服务器版本就是刚传的这一版。
  @Test func aRejectionWhoseServerVersionIsTheOneJustSentIsAcknowledged() async throws {
    let (card, uploaded) = try await editedAndHandedToTheEngine("第一版")
    _ = try await edit(card, "第二版")
    let rejection = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: uploaded])

    await rig.coordinator.handle(.sent(saved: [], failedSaves: [(uploaded, rejection)], deleted: [], failedDeletes: []))

    try await expectNoCopyAndLocalKept(card, body: "第二版")
  }

  /// 另一台设备离线并发编辑仍保留冲突副本。
  @Test func anotherDevicesConcurrentEditStillKeepsBothVersions() async throws {
    let (card, uploaded) = try await editedAndHandedToTheEngine("第一版")
    await rig.coordinator.handle(.sent(saved: [uploaded], failedSaves: [], deleted: [], failedDeletes: []))
    let local = try await edit(card, "本机第二版")
    let other = remoteRecord(.cards, id: card.id, cardFields(project: nil, body: "另一台的版本", modifiedAt: (local["modifiedAt"] as! NSNumber).int64Value + 1_000))

    try await pull([other])

    let conflict = try #require(try await store.conflicts().first)
    #expect(conflict.original.body == "另一台的版本" && conflict.copy.body == "本机第二版")
  }

  /// 抹掉本机数据后从云端重新下载：云端的版本正是本机此前传上去的，必须落地。
  @Test func erasingLocalDataDownloadsTheVersionsThisDeviceUploadedEarlier() async throws {
    let (card, uploaded) = try await editedAndHandedToTheEngine("传上去的")
    await rig.coordinator.handle(.sent(saved: [uploaded], failedSaves: [], deleted: [], failedDeletes: []))
    await rig.coordinator.handle(.cloudDataLost(.deleted))
    try await rig.coordinator.resolve(.eraseLocal)
    #expect(try await store.card(card.id) == nil)

    await rig.coordinator.handle(.fetched(modifications: [uploaded], deletions: []))

    #expect(try await store.card(card.id)?.body == "传上去的")
  }
}
