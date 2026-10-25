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
    let record = try #require(try await rig.coordinator.record(for: rig.recordID(id)))
    #expect(record["notify"] == nil)
    #expect(record["state"] as? String == "thinking")
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
    let record = try #require(try await rig.coordinator.record(for: rig.recordID(id)))
    #expect(record["notify"] == nil && record.encryptedValues["detail"] as? String == "q2")
  }

  /// 通知服务扩展取回记录、在设备上解密后改写文案：等你确认是"会话名 等你拍板" + 问题首行，完成是会话名 + "完成了"。
  @Test func theNotificationExtensionRewritesTheAlertFromTheDecryptedRecord() async throws {
    let rig = try Rig()
    let recorder = PiStateRecorder(store: rig.store, hostID: "mac", timing: ManualTiming().timing)
    let question = PiQuestion(promptID: "p1", kind: .select, text: "要覆盖 public/feed.xml 吗？\n会丢掉手写的条目", options: ["覆盖", "取消"])
    try await recorder.update(sessionID: "s1", state: .waitingForUser, title: "homepage", question: question)

    let state = try #require(try await rig.store.allPiSessionStates().first)
    let record = RecordMapper.record(from: try #require(try await rig.store.syncRow(recordName: state.id.uuidString.lowercased())), zoneID: zone)

    let waiting = try #require(PiAlertText.content(for: record, kind: .waitingForUser))
    #expect(waiting.title == "homepage 等你拍板" && waiting.body == "要覆盖 public/feed.xml 吗？")
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
    let shot = try #require(try await rig.store.addPreviews([(file, "登录页")], sessionID: "s1").first).preview
    let message = try await rig.store.addCueMessage(
      .cue, text: "要合并到 main 吗？", ask: try CueAsking(.merge, action: "把登录页修复合并进 main"),
      shots: [CueShot(preview: shot.id, look: "改后的登录页")])

    let record = try #require(try await rig.coordinator.record(for: rig.recordID(message.id)))
    #expect(record["notify"] as? String == "cue" && record.encryptedValues["text"] as? String == "要合并到 main 吗？" && record["ask"] as? String == "merge")
    let profile = try #require(try await rig.coordinator.record(for: CKRecord.ID(recordName: CueProfile.syncRecordName, zoneID: zone)))
    let text = try #require(CueAlertText.content(message: record, profile: profile))
    #expect(text.title == "小管家" && text.body == "可以把登录页修复合并进 main 吗？\n看图：改后的登录页\n可以 / 以后合并进共享分支都不用问")

    try await rig.simulatePush()
    try await rig.store.endCueQuestion(message.id, .answered(CueAsk.once))
    let answered = try #require(try await rig.coordinator.record(for: rig.recordID(message.id)))
    #expect(answered["notify"] == nil && answered.encryptedValues["answer"] as? String == CueAsk.once)
  }

  // MARK: 到不到你（用户定的规则：回答他那一轮的话推到手机、一轮只响一次；他在 Mac 上开着那一页不推；Cue 值班时会话做完只推归他的停下与留给他的）

  private func flag(_ rig: Rig, _ id: UUID) async throws -> String? {
    try #require(try await rig.coordinator.record(for: rig.recordID(id)))["notify"] as? String
  }

  /// 他发完消息就离开了 App：Cue 回答这一轮的话推到手机，正文是 Cue 的原话；这一轮先发了提问卡就只响提问卡那一下。
  /// 他在 Mac 上开着 Cue 页时不推；手机上开着的不挡（那条可能停在"开着"，手机前台自己不弹）。
  @Test func cueRepliesToHisRoundReachThePhoneOncePerRoundUnlessHeHasTheCuePageOpenOnAMac() async throws {
    let rig = try Rig()
    func reply(_ text: String, startedAt: Date = .now) async throws -> UUID {
      try await rig.store.replyCueRound(startedAt: startedAt, reply: .verbatim(text), as: .cue, answersYou: true)
      return try #require(try await rig.store.cueMessages().last { $0.text == text }).id
    }

    try await rig.store.recordViewing(device: "phone", sessionID: nil, cue: true)
    let fixed = try await reply("登录页修好了，**测试全过**")
    #expect(try await flag(rig, fixed) == "cue")
    let record = try #require(try await rig.coordinator.record(for: rig.recordID(fixed)))
    #expect(CueAlertText.content(message: record, profile: nil)?.body == "登录页修好了，测试全过")

    let round = Date.now
    let card = try await rig.store.addCueMessage(.cue, text: "要推送吗？", ask: try CueAsking(.push, action: "推送登录页的修复"))
    #expect(try await flag(rig, card.id) == "cue")
    #expect(try await flag(rig, reply("问你了", startedAt: round)) == nil)

    try await rig.store.recordMacPresence(host: "mac") { true }
    try await rig.store.recordViewing(device: "mac", sessionID: nil, cue: true)
    #expect(try await flag(rig, reply("合并好了")) == nil)
  }

  /// 会话做完：Cue 不值班时推；值班时会话归它接手不推，只推归他的停下（他刚在里面说过话）与它留给他回的（待回复，正文是会话最后那句回答）；
  /// 他在 Mac 上开着那个会话时都不推。
  @Test func sessionAlertsReachThePhoneOnlyWhenTheStopIsHis() async throws {
    let rig = try Rig()
    let recorder = PiStateRecorder(store: rig.store, hostID: "mac", timing: ManualTiming().timing)
    let session = PiSessionState.recordID(sessionID: "s1")
    func round(_ said: String? = nil) async throws {
      try await recorder.update(sessionID: "s1", state: .thinking, title: "登录页")
      if let said {
        let message = PiChatMessage(sessionID: "s1", entryID: UUID().uuidString, seq: 1, role: .user, text: said, at: .now, deliveryID: nil)
        try await rig.store.writePiTranscript(PiTranscript(sessionID: "s1", messages: [message], recap: PiRecap(lastPrompt: said, lastReply: "改好了\n细节见下")))
      }
      try await recorder.update(sessionID: "s1", state: .settled)
    }

    try await round()
    #expect(try await flag(rig, session) == "settled")
    try await rig.simulatePush()
    try await rig.store.recordMacPresence(host: "mac") { true }
    try await rig.store.recordViewing(device: "mac", sessionID: "s1", cue: false)
    try await round()
    #expect(try await flag(rig, session) == nil)
    try await rig.store.recordViewing(device: "mac", sessionID: nil, cue: false)

    _ = try await rig.store.updateCueProfile {
      $0.hostID = "mac"
      $0.enabledAt = .now
    }
    try await round()
    #expect(try await flag(rig, session) == nil)  // 归 Cue 接手
    try await round("顺便把限流加上")
    #expect(try await flag(rig, session) == "settled")  // 他刚说过话：这一停归他
    try await rig.simulatePush()

    let left = try #require(try await { () async throws -> CueLeft? in
      try await rig.store.leaveToYou("s1")
      return try await rig.store.cueDuty()?.left.first
    }())
    #expect(try await rig.store.flagLeftToYou(left, host: "mac") == session)
    let record = try #require(try await rig.coordinator.record(for: rig.recordID(session)))
    #expect(record["notify"] as? String == "awaitsReply")
    #expect(PiAlertText.content(for: record, kind: .awaitsReply).map { [$0.title, $0.body] } == ["登录页 待回复", "改好了"])
  }

  // MARK: 点通知的路由

  private func payload(subscription: String, record: String) -> [AnyHashable: Any] {
    [
      "aps": ["alert": ["loc-key": "pi_alert_waiting"]],
      "ck": ["ce": 2, "cid": "iCloud.com.example.cuepad", "nid": "n",
             "qry": ["dbs": 1, "fo": 1, "rid": record, "sid": subscription, "zid": "CuePad", "zoid": "__defaultOwner__"]],
    ]
  }

  @Test func tappingANotificationRoutesToTheMessageOrSessionRecord() {
    let id = UUID()
    func tap(_ subscription: String) -> CloudAlert? { CloudAlert(userInfo: payload(subscription: subscription, record: id.uuidString.lowercased())) }
    #expect(tap("cuepad.cue") == .cue(message: id))
    #expect(tap("cuepad.pi.waiting") == .session(PiAlertTap(kind: .waitingForUser, sessionState: id)))
    #expect(tap("cuepad.pi.settled") == .session(PiAlertTap(kind: .settled, sessionState: id)))
    #expect(tap("cuepad.pi.reply") == .session(PiAlertTap(kind: .awaitsReply, sessionState: id)))
    #expect(tap("cuepad.changes") == nil)
  }

}
