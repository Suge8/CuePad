import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

/// Pi"等你确认"与"完成"到手机锁屏：CloudKit 服务端按记录上的通知标志生成可见通知（不依赖静默推送与 App 在后台）。
/// 通知里不能出现加密字段（标题、详情）：文案是本地化 key 的通用句。
@Suite struct PiAlertTests {
  let zone = testZone

  // MARK: 记录映射

  @Test func notifyFlagIsAPlainFieldSoTheServerCanMatchItAndContentStaysEncrypted() async throws {
    let rig = try Rig()
    let recorder = PiStateRecorder(store: rig.store, hostID: "mac", timing: ManualTiming().timing)
    try await recorder.update(sessionID: "s1", state: .thinking, title: "secret title")
    try await recorder.update(sessionID: "s1", state: .waitingForUser, detail: "secret question")

    let state = try #require(try await rig.store.allPiSessionStates().first)
    let record = RecordMapper.record(from: try #require(try await rig.store.syncRow(recordName: state.id.uuidString.lowercased())), zoneID: zone)

    #expect(record["notify"] as? String == "waitingForUser" && record.encryptedValues["notify"] == nil)
    #expect(record["sessionID"] as? String == "s1")
    #expect(record["title"] == nil && record["detail"] == nil)  // 标题与详情只在加密字段里
    #expect(record.encryptedValues["title"] as? String == "secret title")
  }

  /// 状态已经往前走（用户在 Mac 上答了，回到思考中）：通知不再送出。这一种取代是有意的——已恢复工作的会话不该再提示"等你确认"。
  @Test func anAlertForAStateThatHasSinceMovedOnIsNotDelivered() async throws {
    let rig = try Rig()
    let recorder = PiStateRecorder(store: rig.store, hostID: "mac", timing: ManualTiming().timing)
    try await recorder.update(sessionID: "s1", state: .thinking)
    try await recorder.update(sessionID: "s1", state: .waitingForUser)  // 置位，还没上传
    try await recorder.update(sessionID: "s1", state: .thinking)  // 继续工作

    let id = try #require(try await rig.store.allPiSessionStates().first).id
    let record = try #require(await rig.coordinator.record(for: rig.recordID(id)))
    #expect(record["notify"] == nil)
    #expect(record["state"] as? String == "thinking")
  }

  /// 仍在等你确认、只是问题文本变了：上传前标志必须还在，服务端才会通知。
  @Test func aSameStateUpdateBeforeUploadKeepsTheFlag() async throws {
    let rig = try Rig()
    let recorder = PiStateRecorder(store: rig.store, hostID: "mac", timing: ManualTiming().timing)
    try await recorder.update(sessionID: "s1", state: .thinking)
    try await recorder.update(sessionID: "s1", state: .waitingForUser, detail: "要不要覆盖？")
    try await recorder.update(sessionID: "s1", state: .waitingForUser, detail: "要覆盖 a.txt 吗？")

    let id = try #require(try await rig.store.allPiSessionStates().first).id
    let record = try #require(await rig.coordinator.record(for: rig.recordID(id)))
    #expect(record["notify"] as? String == "waitingForUser")
    #expect(record.encryptedValues["detail"] as? String == "要覆盖 a.txt 吗？")
  }

  /// 标志已经上传过，之后同状态的更新不再带标志，订阅不会为同一次等待重复通知。
  @Test func aSameStateUpdateAfterUploadDoesNotAlertAgain() async throws {
    let rig = try Rig()
    let recorder = PiStateRecorder(store: rig.store, hostID: "mac", timing: ManualTiming().timing)
    try await recorder.update(sessionID: "s1", state: .thinking)
    try await recorder.update(sessionID: "s1", state: .waitingForUser, detail: "q1")
    try await rig.coordinator.reconcile()
    try await rig.simulatePush()  // 带标志的记录已被服务端接受

    try await recorder.update(sessionID: "s1", state: .waitingForUser, detail: "q2")

    let id = try #require(try await rig.store.allPiSessionStates().first).id
    let record = try #require(await rig.coordinator.record(for: rig.recordID(id)))
    #expect(record["notify"] == nil && record.encryptedValues["detail"] as? String == "q2")
  }

  /// 标志上传之后，同一条记录的任何别的改动（如对话摘要在本轮结束时更新）都不能把它再带上去：
  /// 服务端把每次"仍然匹配"的更新都当成一次新通知。
  @Test func anUnrelatedWriteAfterUploadDoesNotAlertAgain() async throws {
    let rig = try Rig()
    let recorder = PiStateRecorder(store: rig.store, hostID: "mac", timing: ManualTiming().timing)
    try await recorder.update(sessionID: "s1", state: .thinking)
    try await recorder.update(sessionID: "s1", state: .settled)
    try await rig.coordinator.reconcile()
    try await rig.simulatePush()  // 带标志的记录已被服务端接受

    try await rig.store.writePiTranscript(PiTranscript(sessionID: "s1", messages: [], recap: PiRecap(lastPrompt: "跑测试", lastReply: "全部通过")))

    let id = try #require(try await rig.store.allPiSessionStates().first).id
    let record = try #require(await rig.coordinator.record(for: rig.recordID(id)))
    #expect(record.encryptedValues["lastReply"] as? String == "全部通过")
    #expect(record["notify"] == nil)
  }

  // MARK: 订阅的形状

  @Test func subscriptionsMatchTheFlagAndCarryOnlyGenericLocalizedText() {
    let subscriptions = PiAlertSubscriptions(zoneID: zone).desired()

    #expect(subscriptions.map(\.subscriptionID) == ["cuepad.pi.waiting", "cuepad.pi.settled"])
    #expect(subscriptions.map { ($0 as CKQuerySubscription).predicate.predicateFormat } == [#"notify == "waitingForUser""#, #"notify == "settled""#])
    for subscription in subscriptions {
      #expect(subscription.recordType == "piSessionStates" && subscription.zoneID == zone)
      #expect(subscription.querySubscriptionOptions == [.firesOnRecordCreation, .firesOnRecordUpdate])  // 删除不通知
      let info = try? #require(subscription.notificationInfo)
      #expect(info?.shouldSendContentAvailable == false)  // 可见通知，不是静默推送
      #expect(info?.shouldSendMutableContent == true)  // 手机上的通知服务扩展先拿到，改写成会话名与问题
      #expect(info?.alertBody == nil && info?.alertLocalizationArgs == nil && info?.desiredKeys == nil)
    }
    #expect(subscriptions.map { $0.notificationInfo?.alertLocalizationKey } == ["pi_alert_waiting", "pi_alert_settled"])
  }

  /// 通知服务扩展取回记录、在设备上解密后改写文案：等你确认是"会话名 在等你" + 问题首行，完成是会话名 + "完成了"。
  @Test func theNotificationExtensionRewritesTheAlertFromTheDecryptedRecord() async throws {
    let rig = try Rig()
    let recorder = PiStateRecorder(store: rig.store, hostID: "mac", timing: ManualTiming().timing)
    let question = PiQuestion(promptID: "p1", kind: .select, text: "要覆盖 public/feed.xml 吗？\n会丢掉手写的条目", options: ["覆盖", "取消"])
    try await recorder.update(sessionID: "s1", state: .waitingForUser, title: "homepage", question: question)

    let state = try #require(try await rig.store.allPiSessionStates().first)
    let record = RecordMapper.record(from: try #require(try await rig.store.syncRow(recordName: state.id.uuidString.lowercased())), zoneID: zone)

    let waiting = try #require(PiAlertText.content(for: record, kind: .waitingForUser))
    #expect(waiting.title == "homepage 在等你" && waiting.body == "要覆盖 public/feed.xml 吗？")
    let settled = try #require(PiAlertText.content(for: record, kind: .settled))
    #expect(settled.title == "homepage" && settled.body == "完成了")
  }

  // MARK: 幂等创建与账号切换后重建

  private func store(preloaded: [CKSubscription] = []) -> FakeSubscriptions { FakeSubscriptions(preloaded) }

  @Test func ensuringCreatesMissingSubscriptionsOnceAndThenChangesNothing() async throws {
    let fake = store()
    let manager = PiAlertSubscriptions(zoneID: zone)

    #expect(await manager.ensure(in: fake) == .active)
    #expect(await fake.saved.sorted() == ["cuepad.pi.settled", "cuepad.pi.waiting"])

    await fake.resetCounters()
    #expect(await manager.ensure(in: fake) == .active)
    #expect(await fake.saved.isEmpty)
    #expect(await fake.deleted.isEmpty)
  }

  /// 建立失败不能吞掉：状态带着原因交给界面；之后重试成功即恢复。
  @Test func aFailedEnsureIsReportedAndTheNextOneRecovers() async {
    let fake = store()
    let manager = PiAlertSubscriptions(zoneID: zone)

    await fake.failSaves(with: Boom())
    #expect(await manager.ensure(in: fake) == .failed("没有网络"))

    await fake.failSaves(with: nil)
    #expect(await manager.ensure(in: fake) == .active)
    #expect(await fake.saved.sorted() == ["cuepad.pi.settled", "cuepad.pi.waiting"])
  }

  @Test func driftedSubscriptionsAreReplacedAndStaleOnesOfOursAreRemovedButForeignOnesAreLeftAlone() async throws {
    let manager = PiAlertSubscriptions(zoneID: zone)
    var drifted = manager.desired()[0]
    drifted = CKQuerySubscription(recordType: "piSessionStates", predicate: NSPredicate(format: "notify == %@", "other"), subscriptionID: drifted.subscriptionID, options: [.firesOnRecordCreation])
    let stale = CKQuerySubscription(recordType: "piSessionStates", predicate: NSPredicate(value: true), subscriptionID: "cuepad.pi.old", options: [.firesOnRecordCreation])
    let foreign = CKQuerySubscription(recordType: "other", predicate: NSPredicate(value: true), subscriptionID: "somebody.else", options: [.firesOnRecordCreation])
    let fake = store(preloaded: [drifted, stale, foreign])

    #expect(await manager.ensure(in: fake) == .active)

    #expect(await fake.saved.sorted() == ["cuepad.pi.settled", "cuepad.pi.waiting"])
    #expect(await fake.deleted == ["cuepad.pi.old"])
    #expect(await fake.ids.contains("somebody.else"))
  }

  @Test func aNewAccountsEmptyDatabaseGetsTheSubscriptionsAgain() async throws {
    let manager = PiAlertSubscriptions(zoneID: zone)
    let firstAccount = store()
    _ = await manager.ensure(in: firstAccount)

    let secondAccount = store()  // 账号切换：新账号的数据库里什么都没有
    _ = await manager.ensure(in: secondAccount)

    #expect(await secondAccount.saved.sorted() == ["cuepad.pi.settled", "cuepad.pi.waiting"])
  }

  // MARK: 点通知的路由

  private func payload(subscription: String, record: String) -> [AnyHashable: Any] {
    [
      "aps": ["alert": ["loc-key": "pi_alert_waiting"]],
      "ck": ["ce": 2, "cid": "iCloud.com.sugeh.cuepad", "nid": "n",
             "qry": ["dbs": 1, "fo": 1, "rid": record, "sid": subscription, "zid": "CuePad", "zoid": "__defaultOwner__"]],
    ]
  }

  @Test func tappingANotificationRoutesToTheSessionRecord() {
    let id = UUID()
    let waiting = PiAlertRoute.tap(from: payload(subscription: "cuepad.pi.waiting", record: id.uuidString.lowercased()))
    let settled = PiAlertRoute.tap(from: payload(subscription: "cuepad.pi.settled", record: id.uuidString.lowercased()))
    #expect(waiting == PiAlertTap(kind: .waitingForUser, sessionState: id))
    #expect(settled == PiAlertTap(kind: .settled, sessionState: id))
  }

  @Test func otherNotificationsAreNotOurs() {
    #expect(PiAlertRoute.tap(from: payload(subscription: "somebody.else", record: UUID().uuidString)) == nil)
    #expect(PiAlertRoute.tap(from: payload(subscription: "cuepad.pi.waiting", record: "not-a-uuid")) == nil)
    #expect(PiAlertRoute.tap(from: ["aps": ["alert": "hi"]]) == nil)
  }
}

struct Boom: LocalizedError { var errorDescription: String? { "没有网络" } }

/// 记录保存与删除了哪些订阅；模拟一个账号的私有数据库。
actor FakeSubscriptions: SubscriptionStore {
  private var current: [CKSubscription.ID: CKSubscription]
  private var saveFailure: (any Error)?
  private(set) var saved: [String] = []
  private(set) var deleted: [String] = []
  var ids: Set<String> { Set(current.keys) }

  init(_ preloaded: [CKSubscription]) { current = Dictionary(uniqueKeysWithValues: preloaded.map { ($0.subscriptionID, $0) }) }

  func subscriptions() -> [CKSubscription.ID: CKSubscription] { current }
  func failSaves(with error: (any Error)?) { saveFailure = error }
  func save(_ subscription: CKSubscription) throws {
    if let saveFailure { throw saveFailure }
    current[subscription.subscriptionID] = subscription
    saved.append(subscription.subscriptionID)
  }
  func delete(_ id: CKSubscription.ID) {
    current[id] = nil
    deleted.append(id)
  }
  func resetCounters() {
    saved = []
    deleted = []
  }
}
