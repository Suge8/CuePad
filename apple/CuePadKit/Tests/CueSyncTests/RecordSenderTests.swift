import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

@Suite struct RecordSenderTests {
  let rig = try! Rig()

  actor ScriptedServer: RecordUploader {
    private var script: [@Sendable ([CKRecord]) throws -> SentRecords]
    private(set) var uploads: [[String]] = []
    private(set) var deletions: [String] = []
    private(set) var zonesSaved = 0

    init(_ script: [@Sendable ([CKRecord]) throws -> SentRecords]) { self.script = script }

    func upload(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> SentRecords {
      uploads.append(saving.map(\.recordID.recordName))
      deletions += deleting.map(\.recordName)
      if script.isEmpty { return SentRecords(saved: saving, deleted: deleting) }
      return try script.removeFirst()(saving)
    }

    func saveZone() async throws { zonesSaved += 1 }
  }

  @Test func aWholeRequestRejectedForAMissingZoneCreatesTheZoneAndUploadsAgain() async throws {
    let server = ScriptedServer([{ _ in throw CKError(.zoneNotFound) }])
    let sender = RecordSender(uploader: server, coordinator: rig.coordinator)
    await sender.start()
    let card = try await rig.store.createCard(body: "新装后第一条")

    #expect(await sender.send([rig.id(card.id)]))
    #expect(await server.zonesSaved == 1)
    #expect(try await !rig.reconcileDelta().saves.contains(rig.id(card.id)))  // 别的待推送（默认项目）在后台那一路，不随它返回
    await sender.stop()
  }

  @Test func aRecordTheServerRefusesDoesNotHoldBackLaterUploads() async throws {
    let bad = try await rig.store.createCard(body: "服务器不收这一版")
    let refused = rig.id(bad.id)
    let server = ScriptedServer([
      { records in
        SentRecords(
          saved: records.filter { $0.recordID.recordName != refused },
          failedSaves: records.filter { $0.recordID.recordName == refused }.map { ($0, CKError(.invalidArguments)) })
      }
    ])
    let sender = RecordSender(uploader: server, coordinator: rig.coordinator)
    await sender.start()
    await sender.flush()

    let said = try await rig.store.createCard(body: "之后说的话")
    #expect(await sender.send([rig.id(said.id)]))
    await sender.flush()
    #expect(await server.uploads.filter { $0.contains(refused) }.count == 1)
    await sender.stop()
  }

  @Test func deletingARecordWhoseEditWasRefusedStillReachesTheServer() async throws {
    let card = try await rig.store.createCard(body: "第一版")
    let server = ScriptedServer([
      { records in SentRecords(saved: records) },
      { records in SentRecords(failedSaves: records.map { ($0, CKError(.invalidArguments)) }) },
    ])
    let sender = RecordSender(uploader: server, coordinator: rig.coordinator)
    await sender.start()
    await sender.flush()

    await nextMillisecond()
    try await rig.store.updateCard(card.id) { $0.body = "服务器不收这一版" }
    await sender.flush()
    try await rig.store.purgeCard(card.id)
    await sender.flush()
    #expect(await server.deletions.contains(rig.id(card.id)))
    await sender.stop()
  }

  /// 回答随本机提交在合并窗口后就发，不等会话状态细节的节流：这时还挂着一条工作中的细节，节流走手动时钟、永不到点，等它就会等到测试时限。
  @Test func aNewReplyIsUploadedRightAfterItIsWritten() async throws {
    let server = FakeUploader()
    let sender = RecordSender(uploader: server, coordinator: rig.coordinator)
    await sender.start()
    let recorder = StateRecorder(store: rig.store, hostID: "mac", timing: ManualTiming().timing)  // 节流的定时器不会自己到点
    try await recorder.update(sessionID: "s1", state: .thinking, title: "修登录")
    let state = SessionState.recordID(sessionID: "s1").uuidString.lowercased()
    try await server.uploaded(state)
    try await recorder.update(sessionID: "s1", state: .tool, detail: "bash")  // 挂起的细节
    await sender.flush()  // 发送者闲下来：回答从提交触发开始算

    let reply = ChatMessage(sessionID: "s1", entryID: "a1", seq: 1, role: .pi, text: "改好了，测试全过", at: .now)
    try await rig.store.writeTranscript(SessionTranscript(sessionID: "s1", messages: [reply], recap: Recap(lastPrompt: "修登录", lastReply: "改好了，测试全过")))
    let message = try #require(try RawDB(rig.fixture.url).rows("SELECT id FROM piMessages").first?[0])
    try await server.waitUntil("答复与会话状态再次出现在上传里") { batches in
      batches.contains { $0.saves.contains(message) } && batches.filter { $0.saves.contains(state) }.count >= 2
    }
    await sender.stop()
  }
}
