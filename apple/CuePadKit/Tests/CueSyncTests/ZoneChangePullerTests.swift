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
    /// 按 ID 取整条记录时的服务器内容。
    var server: [CKRecord.ID: CKRecord] = [:]

    init(_ responses: [Result<ZoneChangeBatch, any Error>], server: [CKRecord] = []) {
      self.responses = responses
      self.server = Dictionary(uniqueKeysWithValues: server.map { ($0.recordID, $0) })
    }

    func changes(since token: Data?, idsOnly: Bool) async throws -> ZoneChangeBatch {
      calls.append((token, idsOnly))
      return try responses.removeFirst().get()
    }

    func records(_ ids: [CKRecord.ID]) async throws -> [CKRecord] { ids.compactMap { server[$0] } }
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

  /// 开始拉之前就已经在服务器上的投送请求（如 Mac 刚连上会话时手机已发出的）：取令牌时看到它就按 ID 取整条交给协调器，
  /// 不会被令牌跨过。
  @Test func deliveryRequestsAlreadyOnTheServerWhenTakingTheTokenAreFetchedInFull() async throws {
    let id = UUID()
    let full = remoteRecord(.deliveryRequests, id: id, [
      "content": .text("ping"), "targetKind": .text("app"), "targetName": .text("CuePad"), "targetRef": .null,
      "hostID": .text("mac-a"), "mode": .text("ping"), "cardID": .null, "taskID": .null, "status": .text("pending"),
      "resultDetail": .null, "handledBy": .null, "createdAt": .int(1_000), "completedAt": .null, "modifiedAt": .int(1_000),
    ])
    let idOnly = CKRecord(recordType: "deliveryRequests", recordID: full.recordID)
    let zone = FakeZone([batch("t1", [idOnly]), batch("t2")], server: [full])
    let puller = ZoneChangePuller(source: zone, coordinator: rig.coordinator)

    try await puller.pull()

    #expect(try await rig.store.deliveryRequests().map(\.id) == [id])
  }

  /// 在等的对象还有 Pi 会话状态（手机看着 Pi 页时主动拉，状态要是活的）：取令牌时看到的也按 ID 取整条；
  /// 无关的表（卡片）只推进令牌、不补取。
  @Test func piSessionStatesAlreadyOnTheServerAreFetchedInFullButOtherTablesAreNot() async throws {
    let state = remoteRecord(.piSessionStates, id: PiSessionState.recordID(sessionID: "s1"), [
      "sessionID": .text("s1"), "hostID": .text("mac-a"), "title": .text("修好登录"), "projectID": .null,
      "state": .text("waitingForUser"), "detail": .null, "stateSince": .int(1_000), "createdAt": .int(1_000),
      "modifiedAt": .int(1_000), "notify": .null, "folder": .null, "lastPrompt": .null, "lastReply": .null,
      "question": .null, "busySince": .int(1_000),
    ])
    let (cardID, card) = card("取令牌时已有的卡")
    let zone = FakeZone(
      [batch("t1", [CKRecord(recordType: "piSessionStates", recordID: state.recordID), CKRecord(recordType: "cards", recordID: card.recordID)]), batch("t2")],
      server: [state, card])
    let puller = ZoneChangePuller(source: zone, coordinator: rig.coordinator)

    try await puller.pull()

    #expect(try await rig.store.allPiSessionStates().map(\.state) == [.known(.waitingForUser)])
    #expect(try await rig.store.card(cardID) == nil)
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
