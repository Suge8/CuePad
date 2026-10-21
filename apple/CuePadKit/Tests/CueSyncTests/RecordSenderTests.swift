import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

/// 发送者面对服务器的几种拒绝：新装时同步区还不在、记录被限流。
@Suite(.timeLimit(.minutes(1))) struct RecordSenderTests {
  let rig = try! Rig()

  /// 按顺序回放每批上传的结局（用完之后照单全收），记下每批传了什么、建过几次区。
  actor ScriptedServer: RecordUploader {
    private var script: [@Sendable ([CKRecord]) throws -> SentRecords]
    private(set) var uploads: [[String]] = []
    private(set) var zonesSaved = 0

    init(_ script: [@Sendable ([CKRecord]) throws -> SentRecords]) { self.script = script }

    func upload(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> SentRecords {
      uploads.append(saving.map(\.recordID.recordName))
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
    #expect(try await rig.reconcileDelta().saves.isEmpty)
    await sender.stop()
  }

  /// 一轮做完、回答落进对话：手机多久看到回答取决于它多快传上去。回答（对话与会话近况）随本机提交在合并窗口后就发，
  /// 不等会话状态细节的节流（这时还挂着一条工作中的细节；节流走手动时钟、永不到点，等它就会等到测试时限）。
  @Test func aNewReplyIsUploadedRightAfterItIsWritten() async throws {
    let server = FakeUploader()
    let sender = RecordSender(uploader: server, coordinator: rig.coordinator)
    await sender.start()
    let recorder = PiStateRecorder(store: rig.store, hostID: "mac", timing: ManualTiming().timing)  // 节流的定时器不会自己到点
    try await recorder.update(sessionID: "s1", state: .thinking, title: "修登录")
    let state = PiSessionState.recordID(sessionID: "s1").uuidString.lowercased()
    await server.uploaded(state)
    try await recorder.update(sessionID: "s1", state: .tool, detail: "bash")  // 挂起的细节
    await sender.flush()  // 发送者闲下来：回答从提交触发开始算

    let reply = PiChatMessage(sessionID: "s1", entryID: "a1", seq: 1, role: .pi, text: "改好了，测试全过", at: .now)
    try await rig.store.writePiTranscript(PiTranscript(sessionID: "s1", messages: [reply], recap: PiRecap(lastPrompt: "修登录", lastReply: "改好了，测试全过")))
    let message = try #require(try RawDB(rig.fixture.url).rows("SELECT id FROM piMessages").first?[0])
    await server.waitUntil { batches in
      batches.contains { $0.saves.contains(message) } && batches.filter { $0.saves.contains(state) }.count >= 2
    }
    await sender.stop()
  }
}
