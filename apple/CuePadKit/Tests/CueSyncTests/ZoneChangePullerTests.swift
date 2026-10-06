import CloudKit
import Foundation
import Testing
@testable import CueStore
@testable import CueSync

/// 在等时的加速通道：直接拉同步区的变化（不靠引擎的推送），交给协调器与引擎同一个合并入口。
@Suite struct ZoneChangePullerTests {
  let rig = try! Rig()

  /// 按顺序回放的数据库替身：记下每次被要的令牌与要哪些字段（nil：整条），以及每次按 ID 取了哪些记录。
  actor FakeZone: ZoneChangeSource {
    private(set) var calls: [(token: Data?, keys: [String]?)] = []
    private(set) var fetches: [[CKRecord.ID]] = []
    private var responses: [Result<ZoneChangeBatch, any Error>]
    /// 按 ID 取整条记录时的服务器内容。
    var server: [CKRecord.ID: CKRecord] = [:]

    init(_ responses: [Result<ZoneChangeBatch, any Error>], server: [CKRecord] = []) {
      self.responses = responses
      self.server = Dictionary(uniqueKeysWithValues: server.map { ($0.recordID, $0) })
    }

    func changes(since token: Data?, keys: [String]?) async throws -> ZoneChangeBatch {
      calls.append((token, keys))
      return try responses.removeFirst().get()
    }

    func records(_ ids: [CKRecord.ID]) async throws -> [CKRecord] {
      fetches.append(ids)
      return ids.compactMap { server[$0] }
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
    #expect(calls.map { $0.keys == nil } == [false, true, true])
    #expect(calls.map { $0.token.map { String(decoding: $0, as: UTF8.self) } } == [nil, "t1", "t2"])
    #expect(try await rig.store.card(new)?.body == "之后的新卡")
    #expect(try await rig.store.card(old) == nil)  // 取令牌那一遍只带版本，卡片不补取、不交给协调器
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
    #expect(calls.map { $0.keys == nil } == [false, true, false, true])
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

  // MARK: 取令牌时只补取要追的

  private func piState(_ sessionID: String, state: String, modifiedAt: Int64) -> CKRecord {
    remoteRecord(.piSessionStates, id: PiSessionState.recordID(sessionID: sessionID), [
      "sessionID": .text(sessionID), "hostID": .text("mac-a"), "title": .text(sessionID), "projectID": .null,
      "state": .text(state), "detail": .null, "stateSince": .int(1_000), "createdAt": .int(1_000),
      "modifiedAt": .int(modifiedAt), "notify": .null, "folder": .null, "lastPrompt": .null, "lastReply": .null,
      "question": .null, "busySince": .null,
    ])
  }

  /// 取令牌时那一遍只带版本与状态（`modifiedAt`、`state`），不带正文。
  private func versionOnly(_ full: CKRecord) -> CKRecord {
    let record = CKRecord(recordType: full.recordType, recordID: full.recordID)
    for key in ZoneChangePuller.versionKeys { record[key] = full[key] }
    return record
  }

  /// 几千条 Pi 会话（大多是已同步的历史）时取令牌：已同步且没变的不重取，本地没有的已结束会话不追（引擎会带来），
  /// 只补取本地没有的未结束会话与服务器上更新了的；按 ID 取每次不超过 400 条（CloudKit 单次请求上限）。
  @Test func takingATokenFetchesOnlyMissingLiveOrNewerRecordsInRequestsOfAtMost400() async throws {
    let synced = (0..<2_000).map { piState("synced-\($0)", state: "ended", modifiedAt: 1_000) }
    await rig.coordinator.handle(.fetched(modifications: synced, deletions: []))
    let unchanged = synced[10...].map(versionOnly)
    let newer = synced[..<10].map { piState($0["sessionID"] as! String, state: "thinking", modifiedAt: 2_000) }
    let missingLive = (0..<450).map { piState("live-\($0)", state: "thinking", modifiedAt: 3_000) }
    let missingEnded = (0..<600).map { piState("ended-\($0)", state: "ended", modifiedAt: 3_000) }
    let seen = unchanged + (newer + missingLive + missingEnded).map(versionOnly)
    let zone = FakeZone(
      [.success(ZoneChangeBatch(modifications: seen, deletions: [], token: Data("t1".utf8), moreComing: false)), batch("t2")],
      server: newer + missingLive + missingEnded)
    let puller = ZoneChangePuller(source: zone, coordinator: rig.coordinator)

    try await puller.pull()

    let fetches = await zone.fetches
    #expect(fetches.allSatisfy { $0.count <= 400 })
    #expect(Set(fetches.joined()) == Set((newer + missingLive).map(\.recordID)))
    #expect(try await rig.store.allPiSessionStates().count == 2_000 + 450)
  }
}
