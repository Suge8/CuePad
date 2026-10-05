import CloudKit
import Foundation
import Testing
@testable import CueStore
@testable import CueSync

/// 在等时的加速通道：直接拉同步区的变化（不靠引擎的推送），交给协调器与引擎同一个合并入口。
@Suite struct ZoneChangePullerTests {
  let rig = try! Rig()

  /// 按顺序回放的数据库替身：记下每次被要的令牌与是否只要 ID。
  actor FakeZone: ZoneChangeSource {
    private(set) var calls: [(token: Data?, idsOnly: Bool)] = []
    private var responses: [Result<ZoneChangeBatch, any Error>]

    init(_ responses: [Result<ZoneChangeBatch, any Error>]) { self.responses = responses }

    func changes(since token: Data?, idsOnly: Bool) async throws -> ZoneChangeBatch {
      calls.append((token, idsOnly))
      return try responses.removeFirst().get()
    }
  }

  private func batch(_ token: String, _ records: [CKRecord] = []) -> Result<ZoneChangeBatch, any Error> {
    .success(ZoneChangeBatch(modifications: records, deletions: [], token: Data(token.utf8), moreComing: false))
  }

  private func card(_ body: String, modifiedAt: Int64 = 5_000) -> (UUID, CKRecord) {
    let id = UUID()
    return (id, remoteRecord(.cards, id: id, cardFields(project: nil, body: body, modifiedAt: modifiedAt)))
  }

  @Test func firstPullTakesATokenWithIDsOnlyThenHandsChangesToTheCoordinatorAndAdvancesTheToken() async throws {
    let (old, oldRecord) = card("拉令牌时看到的旧卡")
    let (new, newRecord) = card("之后的新卡")
    let zone = FakeZone([batch("t1", [oldRecord]), batch("t2", [newRecord]), batch("t3")])
    let puller = ZoneChangePuller(source: zone, coordinator: rig.coordinator)

    try await puller.pull()
    try await puller.pull()

    let calls = await zone.calls
    #expect(calls.map(\.idsOnly) == [true, false, false])
    #expect(calls.map { $0.token.map { String(decoding: $0, as: UTF8.self) } } == [nil, "t1", "t2"])
    #expect(try await rig.store.card(new)?.body == "之后的新卡")
    #expect(try await rig.store.card(old) == nil)  // 只要 ID 时拿到的记录没有字段，不交给协调器
  }

  @Test func anExpiredTokenIsDroppedAndTakenAgain() async throws {
    let (id, record) = card("令牌过期后拉到的")
    let zone = FakeZone([batch("t1"), .failure(CKError(.changeTokenExpired)), batch("t5"), batch("t6", [record])])
    let puller = ZoneChangePuller(source: zone, coordinator: rig.coordinator)

    try await puller.pull()

    let calls = await zone.calls
    #expect(calls.map(\.idsOnly) == [true, false, true, false])
    #expect(calls.last?.token.map { String(decoding: $0, as: UTF8.self) } == "t5")
    #expect(try await rig.store.card(id)?.body == "令牌过期后拉到的")
  }

  /// 同一批变化会从两条路径到达（这里拉到的，之后引擎又拉到）：第二次合并不改变任何东西。
  @Test func mergingTheSameBatchTwiceChangesNothing() async throws {
    let (id, record) = card("两条路径都拉到")
    await rig.coordinator.handle(.fetched(modifications: [record], deletions: []))
    let once = try await rig.store.card(id)
    let pending = await rig.queue.saves

    await rig.coordinator.handle(.fetched(modifications: [record], deletions: []))

    #expect(try await rig.store.card(id) == once)
    #expect(try await rig.store.conflicts().isEmpty)
    #expect(await rig.queue.saves == pending)
  }
}
