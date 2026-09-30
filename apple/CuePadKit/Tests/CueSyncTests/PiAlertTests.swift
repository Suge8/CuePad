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

    let state = try #require(try await rig.store.piSessionStates().first)
    let record = RecordMapper.record(from: try #require(try await rig.store.syncRow(recordName: state.id.uuidString.lowercased())), zoneID: zone)

    #expect(record["notify"] as? String == "waitingForUser" && record.encryptedValues["notify"] == nil)
    #expect(record["sessionID"] as? String == "s1")
    #expect(record["title"] == nil && record["detail"] == nil)  // 标题与详情只在加密字段里
    #expect(record.encryptedValues["title"] as? String == "secret title")
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
      #expect(info?.alertBody == nil && info?.alertLocalizationArgs == nil && info?.desiredKeys == nil)
    }
    #expect(subscriptions.map { $0.notificationInfo?.alertLocalizationKey } == ["pi_alert_waiting", "pi_alert_settled"])
  }

  // MARK: 幂等创建与账号切换后重建

  private func store(preloaded: [CKSubscription] = []) -> FakeSubscriptions { FakeSubscriptions(preloaded) }

  @Test func ensuringCreatesMissingSubscriptionsOnceAndThenChangesNothing() async throws {
    let fake = store()
    let manager = PiAlertSubscriptions(zoneID: zone)

    try await manager.ensure(in: fake)
    #expect(await fake.saved.sorted() == ["cuepad.pi.settled", "cuepad.pi.waiting"])

    await fake.resetCounters()
    try await manager.ensure(in: fake)
    #expect(await fake.saved.isEmpty && fake.deleted.isEmpty)
  }

  @Test func driftedSubscriptionsAreReplacedAndStaleOnesOfOursAreRemovedButForeignOnesAreLeftAlone() async throws {
    let manager = PiAlertSubscriptions(zoneID: zone)
    var drifted = manager.desired()[0]
    drifted = CKQuerySubscription(recordType: "piSessionStates", predicate: NSPredicate(format: "notify == %@", "other"), subscriptionID: drifted.subscriptionID, options: [.firesOnRecordCreation])
    let stale = CKQuerySubscription(recordType: "piSessionStates", predicate: NSPredicate(value: true), subscriptionID: "cuepad.pi.old", options: [.firesOnRecordCreation])
    let foreign = CKQuerySubscription(recordType: "other", predicate: NSPredicate(value: true), subscriptionID: "somebody.else", options: [.firesOnRecordCreation])
    let fake = store(preloaded: [drifted, stale, foreign])

    try await manager.ensure(in: fake)

    #expect(await fake.saved.sorted() == ["cuepad.pi.settled", "cuepad.pi.waiting"])
    #expect(await fake.deleted == ["cuepad.pi.old"])
    #expect(await fake.ids.contains("somebody.else"))
  }

  @Test func aNewAccountsEmptyDatabaseGetsTheSubscriptionsAgain() async throws {
    let manager = PiAlertSubscriptions(zoneID: zone)
    let firstAccount = store()
    try await manager.ensure(in: firstAccount)

    let secondAccount = store()  // 账号切换：新账号的数据库里什么都没有
    try await manager.ensure(in: secondAccount)

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

/// 记录保存与删除了哪些订阅；模拟一个账号的私有数据库。
actor FakeSubscriptions: SubscriptionStore {
  private var current: [CKSubscription.ID: CKSubscription]
  private(set) var saved: [String] = []
  private(set) var deleted: [String] = []
  var ids: Set<String> { Set(current.keys) }

  init(_ preloaded: [CKSubscription]) { current = Dictionary(uniqueKeysWithValues: preloaded.map { ($0.subscriptionID, $0) }) }

  func subscriptions() -> [CKSubscription.ID: CKSubscription] { current }
  func save(_ subscription: CKSubscription) {
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
