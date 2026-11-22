import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

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
    #expect(record["title"] == nil && record["detail"] == nil)
    #expect(record.encryptedValues["title"] as? String == "secret title")
  }

  @Test func anAlertForAStateThatHasSinceMovedOnIsNotDelivered() async throws {
    let rig = try Rig()
    let recorder = StateRecorder(store: rig.store, hostID: "mac", timing: ManualTiming().timing)
    try await recorder.update(sessionID: "s1", state: .thinking)
    try await recorder.update(sessionID: "s1", state: .waitingForUser)
    try await recorder.update(sessionID: "s1", state: .thinking)

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
    try await rig.simulatePush()

    try await recorder.update(sessionID: "s1", state: .waitingForUser, detail: "q2")

    let id = try #require(try await rig.store.allSessionStates().first).id
    let record = try #require(try await rig.coordinator.record(for: rig.recordID(id)))
    #expect(record["notify"] == nil && record.encryptedValues["detail"] as? String == "q2")
  }

  @Test func theNotificationExtensionRewritesTheAlertFromTheDecryptedRecord() async throws {
    let rig = try Rig()
    let recorder = StateRecorder(store: rig.store, hostID: "mac", timing: ManualTiming().timing)
    let question = Question(promptID: "p1", kind: .select, text: "要覆盖 public/feed.xml 吗？\n会丢掉手写的条目", options: ["覆盖", "取消"])
    try await recorder.update(sessionID: "s1", state: .thinking, title: "homepage", turnStartedAt: .now)
    try await recorder.update(sessionID: "s1", state: .waitingForUser, question: question)
    let name = try #require(try await rig.store.allSessionStates().first).id.uuidString.lowercased()
    func record() async throws -> CKRecord { RecordMapper.record(from: try #require(try await rig.store.syncRow(recordName: name)), zoneID: zone) }

    let waiting = try #require(AlertText.content(for: try await record(), kind: .waitingForUser))
    #expect(waiting.title == "homepage 等你拍板" && waiting.body == "要覆盖 public/feed.xml 吗？ 会丢掉手写的条目")

    let earlier = Recap(lastPrompt: "看看首页", lastReply: "上一轮说的话", answeredAt: .now.addingTimeInterval(-600))
    try await rig.store.writeTranscript(SessionTranscript(sessionID: "s1", messages: [], recap: earlier))
    let unread = try #require(AlertText.content(for: try await record(), kind: .settled))
    #expect(unread.title == "homepage 新回复" && unread.body == "去看看它说了什么")

    let recap = Recap(lastPrompt: "改首页", lastReply: "## 结论\n**改好了**，`feed.xml` 没动。\n\n```\nswift test\n```\n- 测试全过", answeredAt: .now.addingTimeInterval(1))
    try await rig.store.writeTranscript(SessionTranscript(sessionID: "s1", messages: [], recap: recap))
    let settled = try #require(AlertText.content(for: try await record(), kind: .settled))
    #expect(settled.title == "homepage 新回复" && settled.body == "结论 改好了，feed.xml 没动。 测试全过")
  }

  @Test func aCueMessageFlaggedForPushIsRewrittenFromTheDecryptedRecord() async throws {
    let rig = try Rig()
    try await rig.store.updateCueProfile { $0.name = "小管家" }
    let message = try await rig.store.addCueMessage(.cue, text: "登录页的证书**过期了**，要你续一下", urgent: true)

    let record = try #require(try await rig.coordinator.record(for: rig.recordID(message.id)))
    #expect(record["notify"] as? String == "cue" && record.encryptedValues["text"] as? String == message.text)
    let profile = try #require(try await rig.coordinator.record(for: CKRecord.ID(recordName: CueProfile.syncRecordName, zoneID: zone)))
    let text = try #require(CueAlertText.content(message: record, profile: profile))
    #expect(text.title == "小管家" && text.body == "登录页的证书过期了，要你续一下")
  }

  // MARK: 到不到你

  private func flag(_ rig: Rig, _ id: UUID) async throws -> String? {
    try #require(try await rig.coordinator.record(for: rig.recordID(id)))["notify"] as? String
  }

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
    let urgent = try await rig.store.addCueMessage(.cue, text: "证书过期了，要你续一下", urgent: true)
    #expect(try await flag(rig, urgent.id) == "cue")
    #expect(try await flag(rig, reply("问你了", startedAt: round)) == "said")

    try await rig.store.recordMacPresence(host: "mac") { true }
    try await rig.store.recordViewing(device: "mac", sessionIDs: [], cue: true)
    #expect(try await flag(rig, reply("合并好了")) == "said")
  }

  @Test func sessionAlertsReachThePhoneOnlyWhenTheStopIsHis() async throws {
    let rig = try Rig()
    let recorder = StateRecorder(store: rig.store, hostID: "mac", timing: ManualTiming().timing, bootID: TestBoot.id)
    let session = SessionState.recordID(sessionID: "s1")
    func round(his said: String? = nil) async throws {
      let opener = said.map { _ in TurnOpener(delivery: UUID(), cue: false) }
      try await recorder.update(sessionID: "s1", state: .thinking, title: "登录页", turnStartedAt: .now, turnOpener: opener)
      if let said {
        let message = ChatMessage(sessionID: "s1", entryID: UUID().uuidString, seq: 1, role: .user, text: said, at: .now, deliveryID: opener?.delivery)
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
    #expect(try await flag(rig, session) == nil)
    try await round(his: "顺便把限流加上")
    #expect(try await flag(rig, session) == nil)
    _ = try await rig.store.leaveStopsCueSkips(after: 0)
    let left = try #require(try await rig.store.cueDuty()?.left.first)
    #expect(try await rig.store.flagLeftToYou(left, host: "mac") == session)
    let record = try #require(try await rig.coordinator.record(for: rig.recordID(session)))
    #expect(record["notify"] as? String == "awaitsReply")
    #expect(AlertText.content(for: record, kind: .awaitsReply).map { [$0.title, $0.body] } == ["登录页 新回复", "改好了 细节见下"])
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
