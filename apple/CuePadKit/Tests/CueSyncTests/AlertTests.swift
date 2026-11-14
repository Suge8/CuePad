import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

/// 通知里不能出现加密字段（标题、详情）：文案是本地化 key 的通用句。
@Suite struct AlertTests {
  let zone = testZone

  // MARK: 记录映射

  @Test func notifyFlagIsAPlainFieldSoTheServerCanMatchItAndContentStaysEncrypted() async throws {
    let rig = try Rig()
    let recorder = StateRecorder(store: rig.store, hostID: "mac", timing: ManualTiming().timing)
    try await recorder.update(sessionID: "s1", state: .thinking, title: "secret title")
    try await recorder.update(sessionID: "s1", state: .waitingForUser, detail: "secret question")

    let state = try #require(try await rig.store.allSessionStates().first)
    let record = RecordMapper.record(from: try #require(try await rig.store.syncRow(recordName: state.id.uuidString.lowercased())), zoneID: zone)

    #expect(record["notify"] as? String == "waitingForUser" && record.encryptedValues["notify"] == nil)
    #expect(record["sessionID"] as? String == "s1")
    #expect(record["title"] == nil && record["detail"] == nil)  // 标题与详情只在加密字段里
    #expect(record.encryptedValues["title"] as? String == "secret title")
  }

  /// 这一种取代是有意的：已恢复工作的会话不该再提示"等你确认"。
  @Test func anAlertForAStateThatHasSinceMovedOnIsNotDelivered() async throws {
    let rig = try Rig()
    let recorder = StateRecorder(store: rig.store, hostID: "mac", timing: ManualTiming().timing)
    try await recorder.update(sessionID: "s1", state: .thinking)
    try await recorder.update(sessionID: "s1", state: .waitingForUser)  // 置位，还没上传
    try await recorder.update(sessionID: "s1", state: .thinking)  // 继续工作

    let id = try #require(try await rig.store.allSessionStates().first).id
    let record = try #require(try await rig.coordinator.record(for: rig.recordID(id)))
    #expect(record["notify"] == nil)
    #expect(record["state"] as? String == "thinking")
  }

  @Test func aSameStateUpdateAfterUploadDoesNotAlertAgain() async throws {
    let rig = try Rig()
    let recorder = StateRecorder(store: rig.store, hostID: "mac", timing: ManualTiming().timing)
    try await recorder.update(sessionID: "s1", state: .thinking)
    try await recorder.update(sessionID: "s1", state: .waitingForUser, detail: "q1")
    try await rig.simulatePush()  // 带标志的记录已被服务端接受

    try await recorder.update(sessionID: "s1", state: .waitingForUser, detail: "q2")

    let id = try #require(try await rig.store.allSessionStates().first).id
    let record = try #require(try await rig.coordinator.record(for: rig.recordID(id)))
    #expect(record["notify"] == nil && record.encryptedValues["detail"] as? String == "q2")
  }

  @Test func theNotificationExtensionRewritesTheAlertFromTheDecryptedRecord() async throws {
    let rig = try Rig()
    let recorder = StateRecorder(store: rig.store, hostID: "mac", timing: ManualTiming().timing)
    let question = Question(promptID: "p1", kind: .select, text: "要覆盖 public/feed.xml 吗？\n会丢掉手写的条目", options: ["覆盖", "取消"])
    try await recorder.update(sessionID: "s1", state: .waitingForUser, title: "homepage", question: question)

    let state = try #require(try await rig.store.allSessionStates().first)
    let record = RecordMapper.record(from: try #require(try await rig.store.syncRow(recordName: state.id.uuidString.lowercased())), zoneID: zone)

    let waiting = try #require(AlertText.content(for: record, kind: .waitingForUser))
    #expect(waiting.title == "homepage 等你拍板" && waiting.body == "要覆盖 public/feed.xml 吗？")
    let settled = try #require(AlertText.content(for: record, kind: .settled))
    #expect(settled.title == "homepage" && settled.body == "完成了")
  }

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

  // MARK: 到不到你

  private func flag(_ rig: Rig, _ id: UUID) async throws -> String? {
    try #require(try await rig.coordinator.record(for: rig.recordID(id)))["notify"] as? String
  }

  /// 手机上开着的不挡：那条可能停在"开着"，手机前台自己不弹。
  @Test func cueRepliesToHisRoundReachThePhoneOncePerRoundUnlessHeHasTheCuePageOpenOnAMac() async throws {
    let rig = try Rig()
    func reply(_ text: String, startedAt: Date = .now) async throws -> UUID {
      try await rig.store.replyCueRound(startedAt: startedAt, reply: .verbatim(text), as: .cue, answersYou: true)
      return try #require(try await rig.store.cueMessages().last { $0.text == text }).id
    }

    try await rig.store.recordViewing(device: "phone", sessionIDs: [], cue: true)
    let fixed = try await reply("登录页修好了，**测试全过**")
    #expect(try await flag(rig, fixed) == "cue")
    let record = try #require(try await rig.coordinator.record(for: rig.recordID(fixed)))
    #expect(CueAlertText.content(message: record, profile: nil)?.body == "登录页修好了，测试全过")

    let round = Date.now
    let card = try await rig.store.addCueMessage(.cue, text: "要推送吗？", ask: try CueAsking(.push, action: "推送登录页的修复"))
    #expect(try await flag(rig, card.id) == "cue")
    #expect(try await flag(rig, reply("问你了", startedAt: round)) == "said")  // 只静默叫醒

    try await rig.store.recordMacPresence(host: "mac") { true }
    try await rig.store.recordViewing(device: "mac", sessionIDs: [], cue: true)
    #expect(try await flag(rig, reply("合并好了")) == "said")
  }

  @Test func sessionAlertsReachThePhoneOnlyWhenTheStopIsHis() async throws {
    let rig = try Rig()
    let recorder = StateRecorder(store: rig.store, hostID: "mac", timing: ManualTiming().timing, bootID: TestBoot.id)
    let session = SessionState.recordID(sessionID: "s1")
    func round(_ said: String? = nil) async throws {
      try await recorder.update(sessionID: "s1", state: .thinking, title: "登录页", turnStartedAt: .now)
      if let said {
        let message = ChatMessage(sessionID: "s1", entryID: UUID().uuidString, seq: 1, role: .user, text: said, at: .now, deliveryID: nil)
        let recap = Recap(lastPrompt: said, lastReply: "改好了\n细节见下", answeredAt: .now)
        try await rig.store.writeTranscript(SessionTranscript(sessionID: "s1", messages: [message], recap: recap))
      }
      try await recorder.update(sessionID: "s1", state: .settled)
    }

    try await round()
    #expect(try await flag(rig, session) == "settled")
    try await rig.simulatePush()
    try await rig.store.recordMacPresence(host: "mac", bootID: TestBoot.id) { true }
    try await rig.store.recordViewing(device: "mac", sessionIDs: ["s2", "s1"], cue: false)
    try await round()
    #expect(try await flag(rig, session) == "wake")
    try await rig.simulatePush()
    try await rig.store.recordViewing(device: "mac", sessionIDs: [], cue: false)

    _ = try await rig.store.updateCueProfile {
      $0.hostID = "mac"
      $0.enabledAt = .now
    }
    try await round()
    #expect(try await flag(rig, session) == nil)  // 归 Cue 接手
    try await round("顺便把限流加上")
    #expect(try await flag(rig, session) == nil)  // 做完这一下不推：他发起的这一轮按待回复推
    _ = try await rig.store.leaveHisStops(after: 0)  // 值班的管理器对账时当场留给他回
    let left = try #require(try await rig.store.cueDuty()?.left.first)
    #expect(try await rig.store.flagLeftToYou(left, host: "mac") == session)
    let record = try #require(try await rig.coordinator.record(for: rig.recordID(session)))
    #expect(record["notify"] as? String == "awaitsReply")
    #expect(AlertText.content(for: record, kind: .awaitsReply).map { [$0.title, $0.body] } == ["登录页 新回复", "改好了"])
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
    #expect(tap("cuepad.pi.waiting") == .session(AlertTap(kind: .waitingForUser, sessionState: id)))
    #expect(tap("cuepad.pi.settled") == .session(AlertTap(kind: .settled, sessionState: id)))
    #expect(tap("cuepad.pi.reply") == .session(AlertTap(kind: .awaitsReply, sessionState: id)))
    #expect(tap("cuepad.changes") == nil)
  }

}
