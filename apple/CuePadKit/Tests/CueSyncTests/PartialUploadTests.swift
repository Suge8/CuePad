import CloudKit
import CueStore
import Foundation
import Testing
@testable import CueSync

/// 上传是整条还是只带改动的字段：CKRecord 把每个被 set 的列都算作改动（`changedKeys()`），一条状态记录带着三百个模型的清单（约 38 KB），
/// 而状态每几秒就变一次。服务器已经有同样的大字段时不再 set 它；指纹只来自服务器真正有的值（拉取到的整条记录、被接受的上传）。
@Suite(.timeLimit(.minutes(1))) struct PartialUploadTests {
  let rig = try! Rig()
  var store: CueStore { rig.store }

  private func models(_ count: Int, seed: String = "m") -> PiModelState {
    let options = (0..<count).map { index in
      PiModelOption(key: PiModelKey(provider: "provider-\(seed)", id: "model-\(seed)-\(index)-with-a-long-identifier"), name: "Model \(seed) number \(index)", thinkingLevels: [.off, .low, .high])
    }
    return PiModelState(model: options.first, thinking: .known(.low), models: options)
  }

  /// 这次上传里各改动字段的值合计多少字节（加密的字段也算）。
  private func changedBytes(_ record: CKRecord) -> Int {
    record.changedKeys().reduce(0) { sum, key in
      let value: Any? = record.encryptedValues[key] ?? record[key]
      return sum + ((value as? String)?.utf8.count ?? 8)
    }
  }

  private func accepted(_ id: String) async throws -> CKRecord {
    try await rig.coordinator.reconcile()
    let record = try #require(await rig.coordinator.record(for: CKRecord.ID(recordName: id, zoneID: testZone)))
    await rig.coordinator.handle(.sent(saved: [record], failedSaves: [], deleted: [], failedDeletes: []))
    await rig.queue.clear()
    return record
  }

  @Test func aStateWriteDoesNotResendTheModelListTheServerAlreadyHas() async throws {
    let recorder = PiStateRecorder(store: store, hostID: "mac")
    try await recorder.update(sessionID: "s", state: .thinking, title: "t", modelState: models(300))
    let id = try #require(try await store.allPiSessionStates().first).id.uuidString.lowercased()
    let first = try await accepted(id)

    try await recorder.update(sessionID: "s", state: .settled)
    let second = try await accepted(id)

    #expect(first.changedKeys().contains("models"))
    #expect(!second.changedKeys().contains("models"))
    #expect(second.changedKeys().contains("state"))
    print("上传字节：首次 \(changedBytes(first))，之后 \(changedBytes(second))")
    #expect(changedBytes(first) > 30_000)
    #expect(changedBytes(second) < 2_000)
    // 只发了改动的字段，本机照样记为已推送：不会再变成待推送
    #expect(try await rig.reconcileDelta().saves.isEmpty)
  }

  @Test func aChangedModelListIsSentAgain() async throws {
    let recorder = PiStateRecorder(store: store, hostID: "mac")
    try await recorder.update(sessionID: "s", state: .thinking, title: "t", modelState: models(300))
    let id = try #require(try await store.allPiSessionStates().first).id.uuidString.lowercased()
    _ = try await accepted(id)

    try await recorder.update(sessionID: "s", state: .settled, modelState: models(300, seed: "other"))

    #expect(try await accepted(id).changedKeys().contains("models"))
  }

  private func bigBody(_ mark: String) -> String { mark + String(repeating: "正文", count: 400) }

  @Test func whatAnotherDeviceChangedOnTheServerIsNotMistakenForWhatTheServerStillHas() async throws {
    let card = try await store.createCard(in: nil, body: bigBody("甲"))
    _ = try await accepted(rig.id(card.id))
    // 另一台设备把正文改成乙并上传；本机收下（服务器上现在是乙）
    let server = remoteRecord(.cards, id: card.id, cardFields(project: nil, body: bigBody("乙"), modifiedAt: 9_000_000_000_000))
    await rig.coordinator.handle(.fetched(modifications: [server], deletions: []))
    // 本机把它改回甲：服务器上是乙，必须发
    try await store.updateCard(card.id) { $0.body = bigBody("甲") }

    #expect(try await accepted(rig.id(card.id)).changedKeys().contains("body"))
  }

  @Test func aRejectedUploadStillCarriesTheChangeTheNextTime() async throws {
    let card = try await store.createCard(in: nil, body: bigBody("甲"))
    _ = try await accepted(rig.id(card.id))
    try await store.updateCard(card.id) { $0.body = bigBody("乙") }
    try await rig.coordinator.reconcile()
    let attempt = try #require(await rig.coordinator.record(for: rig.recordID(card.id)))
    #expect(attempt.changedKeys().contains("body"))

    await rig.coordinator.handle(.sent(saved: [], failedSaves: [(attempt, CKError(.networkFailure))], deleted: [], failedDeletes: []))

    #expect(try #require(await rig.coordinator.record(for: rig.recordID(card.id))).changedKeys().contains("body"))
  }

  @Test func afterARestartTheFirstUploadOfARecordIsWhole() async throws {
    let card = try await store.createCard(in: nil, body: bigBody("甲"))
    _ = try await accepted(rig.id(card.id))
    try await store.updateCard(card.id) { $0.isPinned = true }
    let restarted = SyncCoordinator(store: store, queue: rig.queue, zoneID: testZone)

    let record = try #require(await restarted.record(for: rig.recordID(card.id)))

    #expect(record.changedKeys().contains("body"))  // 指纹只在内存里，重启后不知道服务器有什么
  }
}
