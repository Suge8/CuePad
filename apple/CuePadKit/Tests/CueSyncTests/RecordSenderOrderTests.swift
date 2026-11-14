import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

/// 马上传的答复：先后由替身控制（上传挂着等放行），不靠负载。
/// 每条都核对同一件事：答收下时，服务器上已有要的那一刻库里的那一版。
/// 先后由替身控制，等的是替身记下的进展；等不到就记一条说出在等什么的问题，不挂住也不假通过。
private func until(_ what: String, _ condition: () async -> Bool) async {
  do { try await eventually(what, condition) } catch { Issue.record(error) }
}

@Suite struct RecordSenderOrderTests {
  let rig = try! Rig()

  /// 上传挂着等放行。
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

    /// 之后的上传从 0 数起、挂着等放行。
    func hold() {
      (calls, released, gating) = (0, [], true)
    }

    func release(_ index: Int) {
      released.insert(index)
      holds.removeValue(forKey: index)?.resume()
    }

    /// 放行所有挂着的与之后的上传。
    func open() {
      gating = false
      holds.values.forEach { $0.resume() }
      holds = [:]
    }

    func untilCalls(_ count: Int) async { await until("第 \(count) 次上传发出") { calls >= count } }
  }

  /// 起好发送者，把库里已有的待推送发完；之后的上传挂着等放行。
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

  /// 同一条连要两次、中间改过：第二次只在新版收下后答，答的那一刻服务器上已是新版。
  @Test func askedTwiceWithAnEditBetweenIsAnsweredWithTheNewVersion() async throws {
    let server = Gated()
    let (r, R) = try await card("r1")
    let sender = await started(server)
    try await edit(r, "r2")
    let first = Task { await sender.send([R]) }
    await server.untilCalls(1)  // r2 那一批在路上、挂着
    try await edit(r, "r3")
    let second = Task { () -> (Bool, String?) in
      let sent = await sender.send([R])
      return (sent, await server.bodies[R])
    }
    await server.release(0)  // r2 收下：答不了第二次
    await server.untilCalls(2)  // r3 那一批已在路上、挂着：此刻答了就是拿 r2 答的
    await server.open()
    #expect(await first.value)
    let (sent, body) = await second.value
    #expect(sent)
    #expect(body == "r3")
    await sender.stop()
  }

  /// 断网时答没传上，网络回来再要就传上。
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

  /// 一批里服务器拒了一条：这次答没传上，同批收下的单独要答收下，再要被拒的那条当场答没传上。
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
