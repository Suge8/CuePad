import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

private func until(_ what: String, _ condition: () async -> Bool) async {
  do { try await eventually(what, condition) } catch { Issue.record(error) }
}

@Suite struct RecordSenderOrderTests {
  let rig = try! Rig()

  actor Gated: RecordUploader {
    private(set) var calls = 0
    private(set) var bodies: [String: String] = [:]
    var gating = true
    var refused: Set<String> = []
    var offline = false
    private var holds: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<Int> = []

    func set(gating: Bool? = nil, refused: Set<String>? = nil, offline: Bool? = nil) {
      if let gating { self.gating = gating }
      if let refused { self.refused = refused }
      if let offline { self.offline = offline }
    }

    func upload(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> SentRecords {
      let index = calls
      calls += 1
      if gating, !released.contains(index) { await withCheckedContinuation { holds[index] = $0 } }
      if offline { throw CKError(.networkUnavailable) }
      let bad = saving.filter { refused.contains($0.recordID.recordName) }
      let good = saving.filter { !refused.contains($0.recordID.recordName) }
      for record in good { bodies[record.recordID.recordName] = record.encryptedValues["body"] as? String }
      return SentRecords(saved: good, failedSaves: bad.map { ($0, CKError(.invalidArguments)) }, deleted: deleting)
    }

    func saveZone() async throws {}

    func hold() {
      (calls, released, gating) = (0, [], true)
    }

    func release(_ index: Int) {
      released.insert(index)
      holds.removeValue(forKey: index)?.resume()
    }

    func open() {
      gating = false
      holds.values.forEach { $0.resume() }
      holds = [:]
    }

    func untilCalls(_ count: Int) async { await until("第 \(count) 次上传发出") { calls >= count } }
  }

  func started(_ server: Gated) async -> RecordSender {
    let sender = RecordSender(uploader: server, coordinator: rig.coordinator)
    await server.set(gating: false)
    await sender.start()
    await sender.flush()
    await server.hold()
    return sender
  }

  func card(_ body: String) async throws -> (UUID, String) {
    let card = try await rig.store.createCard(body: body)
    return (card.id, rig.id(card.id))
  }

  func edit(_ id: UUID, _ body: String) async throws {
    await nextMillisecond()
    try await rig.store.updateCard(id) { $0.body = body }
  }

  @Test func askedTwiceWithAnEditBetweenIsAnsweredWithTheNewVersion() async throws {
    let server = Gated()
    let (r, R) = try await card("r1")
    let sender = await started(server)
    try await edit(r, "r2")
    let first = Task { await sender.send([R]) }
    await server.untilCalls(1)
    try await edit(r, "r3")
    let second = Task { () -> (Bool, String?) in
      let sent = await sender.send([R])
      return (sent, await server.bodies[R])
    }
    await server.release(0)
    await server.untilCalls(2)
    await server.open()
    #expect(await first.value)
    let (sent, body) = await second.value
    #expect(sent)
    #expect(body == "r3")
    await sender.stop()
  }

  @Test func offlineIsAnsweredAsNotSentAndTheNextAskAfterReconnectingSends() async throws {
    let server = Gated()
    let (r, R) = try await card("r1")
    let sender = await started(server)
    await server.set(gating: false, offline: true)
    try await edit(r, "r2")
    #expect(await sender.send([R]) == false)
    await server.set(offline: false)
    #expect(await sender.send([R]))
    #expect(await server.bodies[R] == "r2")
    await sender.stop()
  }

  @Test func aPartlyRefusedBatchAnswersEachRecordOnItsOwn() async throws {
    let server = Gated()
    let (a, A) = try await card("a1"), (b, B) = try await card("b1")
    let sender = await started(server)
    await server.set(gating: false, refused: [B])
    try await edit(a, "a2")
    try await edit(b, "b2")
    #expect(await sender.send([A, B]) == false)
    #expect(await sender.send([B]) == false)
    #expect(await sender.send([A]))
    #expect(await server.bodies[A] == "a2")
    await sender.stop()
  }
}
