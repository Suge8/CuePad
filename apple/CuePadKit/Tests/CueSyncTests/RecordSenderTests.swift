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
    let card = try await rig.store.createCard(in: nil, body: "新装后第一条")

    #expect(await sender.send([rig.id(card.id)]))
    #expect(await server.zonesSaved == 1)
    #expect(try await rig.reconcileDelta().saves.isEmpty)
    await sender.stop()
  }

  /// 同批里一条被限流（服务器要求等 60 秒）、一条收下：被限流的不立刻原样重传。
  @Test func aRateLimitedRecordWaitsInsteadOfBeingResentRightAway() async throws {
    let limited = CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 60.0])
    let server = ScriptedServer([{ records in SentRecords(saved: [records[0]], failedSaves: [(records[1], limited)]) }])
    let sender = RecordSender(uploader: server, coordinator: rig.coordinator)
    _ = try await rig.store.createCard(in: nil, body: "一")
    _ = try await rig.store.createCard(in: nil, body: "二")
    await sender.start()
    await sender.flush()

    try await Task.sleep(for: .milliseconds(300))
    #expect(await server.uploads.count == 1)
    #expect(try await rig.reconcileDelta().saves.count == 1)  // 被限流的那条仍待推送
    await sender.stop()
  }
}
