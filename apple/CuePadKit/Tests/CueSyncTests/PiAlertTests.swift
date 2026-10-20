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
    try await rig.simulatePush()  // 带标志的记录已被服务端接受

    try await recorder.update(sessionID: "s1", state: .waitingForUser, detail: "q2")

    let id = try #require(try await rig.store.allPiSessionStates().first).id
    let record = try #require(await rig.coordinator.record(for: rig.recordID(id)))
    #expect(record["notify"] == nil && record.encryptedValues["detail"] as? String == "q2")
  }

  // MARK: 订阅的形状

  @Test func subscriptionsMatchTheFlagAndCarryOnlyGenericLocalizedText() throws {
    let all = AlertSubscriptions(zoneID: zone).desired()
    let subscriptions = all.compactMap { $0 as? CKQuerySubscription }

    #expect(all.map(\.subscriptionID) == ["cuepad.pi.waiting", "cuepad.pi.settled", "cuepad.cue", "cuepad.changes"])
    let changes = try #require(all.last as? CKDatabaseSubscription)  // 同步区有变化的静默推送：收到就拉
    #expect(changes.notificationInfo?.shouldSendContentAvailable == true && changes.notificationInfo?.alertLocalizationKey == nil)
    #expect(
      subscriptions.map { $0.predicate.predicateFormat }
        == [#"notify == "waitingForUser""#, #"notify == "settled""#, #"notify == "cue""#])
    #expect(subscriptions.map(\.recordType) == ["piSessionStates", "piSessionStates", "cueMessages"])
    for subscription in subscriptions {
      #expect(subscription.zoneID == zone)
      #expect(subscription.querySubscriptionOptions == [.firesOnRecordCreation, .firesOnRecordUpdate])  // 删除不通知
      let info: CKSubscription.NotificationInfo? = subscription.notificationInfo
      #expect(info?.shouldSendContentAvailable == false)  // 可见通知，不是静默推送
      #expect(info?.shouldSendMutableContent == true)  // 手机上的通知服务扩展先拿到，改写成会话名与问题
      #expect(info?.alertBody == nil && info?.alertLocalizationArgs == nil && info?.desiredKeys == nil)
    }
    #expect(subscriptions.map { $0.notificationInfo?.alertLocalizationKey } == ["pi_alert_waiting", "pi_alert_settled", "cue_alert"])
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

  /// Cue 的消息："等你"写下就带推送标志（明文字段），随那一次上传送出，服务端收下后本机清掉，之后的改动（你回答了）不再带它；
  /// 远端带回来的标志不留。文案由通知服务扩展改写成 Cue 的名字与要你定什么（不露原话）、点名的图各看什么，附上选项。
  @Test func aCueMessageFlaggedForPushGoesUpOnceAndIsRewrittenFromTheDecryptedRecord() async throws {
    let rig = try Rig()
    try await rig.store.updateCueProfile { $0.name = "小管家" }
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
    try Data("png".utf8).write(to: file)
    let shot = try #require(try await rig.store.addPreviews(filesAt: [file], title: "登录页", sessionID: "s1").first).preview
    let message = try await rig.store.addCueMessage(
      .cue, text: "要合并到 main 吗？", ask: try CueAsking(.merge, action: "把登录页修复合并进 main", shots: [CueShot(preview: shot.id, look: "改后的登录页")]))

    let record = try #require(await rig.coordinator.record(for: rig.recordID(message.id)))
    #expect(record["notify"] as? String == "cue" && record.encryptedValues["text"] as? String == "要合并到 main 吗？" && record["ask"] as? String == "merge")
    let profile = try #require(await rig.coordinator.record(for: CKRecord.ID(recordName: CueProfile.syncRecordName, zoneID: zone)))
    let text = try #require(CueAlertText.content(message: record, profile: profile))
    #expect(text.title == "小管家" && text.body == "可以把登录页修复合并进 main 吗？\n看图：改后的登录页\n可以 / 以后合并进共享分支都不用问")

    try await rig.simulatePush()
    try await rig.store.endCueQuestion(message.id, .answered(CueAsk.once))
    let answered = try #require(await rig.coordinator.record(for: rig.recordID(message.id)))
    #expect(answered["notify"] == nil && answered.encryptedValues["answer"] as? String == CueAsk.once)
  }

  /// 他发完消息就离开了 App：Cue 回答这一轮的回复推到手机；他正在 Mac 上开着 Cue 页、或开着那个会话时不推（不重复打扰）。
  /// 手机上开着的不挡推送：那条可能停在"开着"（崩在前台、进后台时没网），手机前台收到时自己按此刻开着哪页不弹。
  @Test func cueRepliesAndSessionAlertsReachThePhoneUnlessHeHasThatPageOpenOnAMac() async throws {
    let rig = try Rig()
    func flag(_ id: UUID) async throws -> String? { try #require(await rig.coordinator.record(for: rig.recordID(id)))["notify"] as? String }
    func reply(_ text: String) async throws -> UUID {
      try await rig.store.replyCueRound(startedAt: .now, reply: text, as: .cue, answersYou: true)
      return try #require(try await rig.store.cueMessages().last { $0.text == text }).id
    }

    try await rig.store.recordViewing(device: "phone", sessionID: nil, cue: true)
    #expect(try await flag(reply("登录页修好了")) == "cue")
    try await rig.store.replyCueRound(startedAt: .now, reply: "看过了", as: .note, answersYou: false)  // 自己醒来那一轮的动态
    #expect(try await flag(try #require(try await rig.store.cueMessages().last).id) == nil)

    try await rig.store.recordMacPresence(host: "mac") { true }
    try await rig.store.recordViewing(device: "mac", sessionID: nil, cue: true)
    #expect(try await flag(reply("合并好了")) == nil)

    let recorder = PiStateRecorder(store: rig.store, hostID: "mac", timing: ManualTiming().timing)
    try await recorder.update(sessionID: "s1", state: .thinking)
    try await rig.store.recordViewing(device: "mac", sessionID: "s1", cue: false)
    try await recorder.update(sessionID: "s1", state: .settled)
    let session = try #require(try await rig.store.allPiSessionStates().first).id
    #expect(try await flag(session) == nil)
    #expect(try await flag(reply("又好了")) == "cue")  // 离开了 Cue 页

    try await rig.store.recordViewing(device: "mac", sessionID: nil, cue: false)
    try await recorder.update(sessionID: "s1", state: .thinking)
    try await recorder.update(sessionID: "s1", state: .settled)
    #expect(try await flag(session) == "settled")
  }

  // MARK: 幂等创建

  private func store(preloaded: [CKSubscription] = []) -> FakeSubscriptions { FakeSubscriptions(preloaded) }

  @Test func ensuringCreatesMissingSubscriptionsOnceAndThenChangesNothing() async throws {
    let fake = store()
    let manager = AlertSubscriptions(zoneID: zone)

    #expect(await manager.ensure(in: fake) == .active)
    #expect(await fake.saved.sorted() == ["cuepad.changes", "cuepad.cue", "cuepad.pi.settled", "cuepad.pi.waiting"])

    await fake.resetCounters()
    #expect(await manager.ensure(in: fake) == .active)
    #expect(await fake.saved.isEmpty)
    #expect(await fake.deleted.isEmpty)
  }

  /// 服务端拒绝时 localizedDescription 往往只剩"未能完成操作（错误 4）"，真正的原因在服务端说明与底层错误里：
  /// 状态必须带着它们，否则只能靠猜（生产环境拒绝创建查询订阅就是这样被藏起来的）。
  @Test func aServerRejectionKeepsTheServersReason() async {
    let fake = store()
    let rejection = CKError(
      .invalidArguments,
      userInfo: [
        "ServerErrorDescription": "attempting to create a subscription in a production container",
        NSUnderlyingErrorKey: NSError(domain: "CKInternalErrorDomain", code: 2006),
      ])
    await fake.failSaves(with: rejection)

    guard case .failed(let reason) = await AlertSubscriptions(zoneID: zone).ensure(in: fake) else {
      Issue.record("没有报告失败")
      return
    }
    #expect(reason.contains("attempting to create a subscription in a production container"))
    #expect(reason.contains("2006"))
  }

  @Test func driftedSubscriptionsAreReplacedAndStaleOnesOfOursAndForeignDatabaseOnesAreRemovedButForeignQueriesAreLeftAlone() async throws {
    let manager = AlertSubscriptions(zoneID: zone)
    var drifted = manager.desired()[0]
    drifted = CKQuerySubscription(recordType: "piSessionStates", predicate: NSPredicate(format: "notify == %@", "other"), subscriptionID: drifted.subscriptionID, options: [.firesOnRecordCreation])
    let stale = CKQuerySubscription(recordType: "piSessionStates", predicate: NSPredicate(value: true), subscriptionID: "cuepad.pi.old", options: [.firesOnRecordCreation])
    let foreign = CKQuerySubscription(recordType: "other", predicate: NSPredicate(value: true), subscriptionID: "somebody.else", options: [.firesOnRecordCreation])
    let engines = CKDatabaseSubscription(subscriptionID: "engine-made")  // CKSyncEngine 当年建的：和我们的静默推送重复
    let fake = store(preloaded: [drifted, stale, foreign, engines])

    #expect(await manager.ensure(in: fake) == .active)

    #expect(await fake.saved.sorted() == ["cuepad.changes", "cuepad.cue", "cuepad.pi.settled", "cuepad.pi.waiting"])
    #expect(await fake.deleted.sorted() == ["cuepad.pi.old", "engine-made"])
    #expect(await fake.ids.contains("somebody.else"))
  }

  // MARK: 点通知的路由

  private func payload(subscription: String, record: String) -> [AnyHashable: Any] {
    [
      "aps": ["alert": ["loc-key": "pi_alert_waiting"]],
      "ck": ["ce": 2, "cid": "iCloud.com.sugeh.cuepad", "nid": "n",
             "qry": ["dbs": 1, "fo": 1, "rid": record, "sid": subscription, "zid": "CuePad", "zoid": "__defaultOwner__"]],
    ]
  }

  @Test func tappingACueNotificationRoutesToTheMessage() {
    let id = UUID()
    #expect(CueAlertRoute.message(from: payload(subscription: "cuepad.cue", record: id.uuidString.lowercased())) == id)
    #expect(CueAlertRoute.message(from: payload(subscription: "cuepad.pi.waiting", record: id.uuidString.lowercased())) == nil)
    #expect(PiAlertRoute.tap(from: payload(subscription: "cuepad.cue", record: id.uuidString.lowercased())) == nil)
  }

  @Test func tappingANotificationRoutesToTheSessionRecord() {
    let id = UUID()
    let waiting = PiAlertRoute.tap(from: payload(subscription: "cuepad.pi.waiting", record: id.uuidString.lowercased()))
    let settled = PiAlertRoute.tap(from: payload(subscription: "cuepad.pi.settled", record: id.uuidString.lowercased()))
    #expect(waiting == PiAlertTap(kind: .waitingForUser, sessionState: id))
    #expect(settled == PiAlertTap(kind: .settled, sessionState: id))
  }

}

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
