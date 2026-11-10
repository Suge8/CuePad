import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

/// 马上传的答复与各路先后：先后由替身控制（上传挂着等放行、"区不存在"的逐条拒绝把那一批的收尾拖在作答之后），不靠负载。
/// 每条都核对同一件事：答收下时，服务器上已有要的那一刻库里的那一版。
@Suite struct RecordSenderOrderTests {
  let rig = try! Rig()

  /// 上传挂着等放行；`zoneMissing` 里的按"区不存在"逐条拒绝，随后的建区也挂着等放行。
  actor Gated: RecordUploader {
    private(set) var calls = 0
    private(set) var bodies: [String: String] = [:]
    var gating = true
    var zoneMissing: Set<String> = []
    var refused: Set<String> = []
    var offline = false
    private(set) var zoneWaiting = false
    private var holds: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<Int> = []
    private var zoneHold: CheckedContinuation<Void, Never>?
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var zoneWaiters: [CheckedContinuation<Void, Never>] = []

    func set(gating: Bool? = nil, zoneMissing: Set<String>? = nil, refused: Set<String>? = nil, offline: Bool? = nil) {
      if let gating { self.gating = gating }
      if let zoneMissing { self.zoneMissing = zoneMissing }
      if let refused { self.refused = refused }
      if let offline { self.offline = offline }
    }

    func upload(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> SentRecords {
      let index = calls
      calls += 1
      callWaiters.removeAll { count, waiter in
        guard calls >= count else { return false }
        waiter.resume()
        return true
      }
      if gating, !released.contains(index) { await withCheckedContinuation { holds[index] = $0 } }
      if offline { throw CKError(.networkUnavailable) }
      let missing = saving.filter { zoneMissing.contains($0.recordID.recordName) }
      let bad = saving.filter { refused.contains($0.recordID.recordName) }
      let good = saving.filter { !zoneMissing.contains($0.recordID.recordName) && !refused.contains($0.recordID.recordName) }
      for record in good { bodies[record.recordID.recordName] = record.encryptedValues["body"] as? String }
      return SentRecords(
        saved: good, failedSaves: missing.map { ($0, CKError(.zoneNotFound)) } + bad.map { ($0, CKError(.invalidArguments)) },
        deleted: deleting)
    }

    func saveZone() async throws {
      guard !zoneMissing.isEmpty else { return }
      zoneWaiting = true
      zoneWaiters.forEach { $0.resume() }
      zoneWaiters = []
      await withCheckedContinuation { zoneHold = $0 }
      zoneWaiting = false
    }

    /// 之后的上传从 0 数起、挂着等放行。
    func hold() {
      (calls, released, gating) = (0, [], true)
    }

    func release(_ index: Int) {
      released.insert(index)
      holds.removeValue(forKey: index)?.resume()
    }

    /// 放行所有挂着的与之后的上传，建区也放行。
    func open() {
      gating = false
      zoneMissing = []
      holds.values.forEach { $0.resume() }
      holds = [:]
      zoneHold?.resume()
      zoneHold = nil
    }

    func untilCalls(_ count: Int) async {
      if calls >= count { return }
      await withCheckedContinuation { callWaiters.append((count, $0)) }
    }

    func untilZoneWaiting() async {
      if zoneWaiting { return }
      await withCheckedContinuation { zoneWaiters.append($0) }
    }
  }

  /// 一次马上传的答复，一次只等一个。
  actor Answer {
    private var result: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?
    func set(_ value: Bool) {
      result = value
      waiter?.resume(returning: value)
    }
    var value: Bool {
      get async {
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
      }
    }
  }

  /// 要马上传，返回时这次已在发送者那里记下（之后放行什么，它都赶上了）。
  func ask(_ sender: RecordSender, _ names: Set<String>) async -> Answer {
    let before = await sender.asks
    let answer = Answer()
    Task { await answer.set(await sender.send(names)) }
    while await sender.asks == before { await Task.yield() }
    return answer
  }

  /// 起好发送者，把库里已有的待推送发完；之后的上传挂着等放行。
  func started(_ server: Gated, step: @escaping @Sendable (RecordSender.Step) async -> Void = { _ in }) async -> RecordSender {
    let sender = RecordSender(uploader: server, coordinator: rig.coordinator, step: step)
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
    try await Task.sleep(for: .milliseconds(3))  // 修改时间是毫秒
    try await rig.store.updateCard(id) { $0.body = body }
  }

  /// 第二次要同一条，落在第一批已作答、还没收尾之间（这一版已被第一批收下，其间没改）：照样答收下，不挂住。
  @Test func askedAgainAfterTheBatchAnsweredButBeforeItEnded() async throws {
    let server = Gated()
    let (r, R) = try await card("r1"), (d, D) = try await card("d1")
    let sender = await started(server)
    try await edit(r, "r2")
    try await edit(d, "d2")
    await server.set(zoneMissing: [D])
    let first = await ask(sender, [R, D])
    await server.untilCalls(1)
    await server.release(0)
    await server.untilZoneWaiting()  // R 已作答，那一批还在建区
    let second = await ask(sender, [R])
    await server.open()
    #expect(await second.value)
    #expect(await server.bodies[R] == "r2")
    _ = await first.value
    await sender.stop()
  }

  /// 两批同时回来：第二次要 R 时它还在第一批里（其间没改），R 那批先作答、还在收尾，S 那批先收尾：照样答收下，不挂住（CI 上卡满 120 秒的那一次）。
  @Test func twoBatchesReturnTogetherAndTheLaterAskIsStillAnswered() async throws {
    let server = Gated()
    let (r, R) = try await card("r1"), (s, S) = try await card("s1"), (d, D) = try await card("d1")
    let sender = await started(server)
    try await edit(r, "r2")
    try await edit(d, "d2")
    await server.set(zoneMissing: [D])
    let first = await ask(sender, [R, D])
    await server.untilCalls(1)
    try await edit(s, "s2")
    let second = await ask(sender, [S, R])
    await server.untilCalls(2)
    await server.release(0)
    await server.untilZoneWaiting()
    await server.release(1)
    while await sender.inFlight.contains(S) { await Task.yield() }  // S 那批先收尾，R 那批还在建区
    await server.open()
    #expect(await second.value)
    #expect(await server.bodies[R] == "r2")
    _ = await first.value
    await sender.stop()
  }

  /// 后台那一路读到 V1 之后、进 `inFlight` 之前改成 V2 并马上传，马上传那一趟晚于后台那一批进 `inFlight`：V1 收下不算答复。
  @Test func askedWhileTheBackgroundBatchWasPickedIsNotAnsweredWithTheOlderVersion() async throws {
    let server = Gated()
    let (r, R) = try await card("r1")
    let order = Order()
    let sender = await started(server) { await order.at($0) }
    try await edit(r, "r2")
    let store = rig.store
    await order.arm(
      picked: {
        try? await Task.sleep(for: .milliseconds(3))
        try? await store.updateCard(r) { $0.body = "r3" }
        return await self.ask(sender, [R])
      },
      reserving: { await server.untilCalls(1) })  // 后台那一批（V1）已在路上
    await sender.kick()
    await server.untilCalls(1)
    await server.release(0)  // V1（r2）收下
    await server.untilCalls(2)  // 新版那一批已在路上、挂着：此刻答了就是拿 V1 答的
    #expect(await sender.waited.contains(R))
    await server.open()
    #expect(await order.answer.value)
    #expect(await server.bodies[R] == "r3")
    await sender.stop()
  }

  /// 各做一次：后台那一路挑完批时改库并马上传，那一趟占下之前等到后台那一批在路上。
  actor Order {
    private var picked: (@Sendable () async -> Answer)?
    private var reserving: (@Sendable () async -> Void)?
    private var made: Answer?
    private var waiter: CheckedContinuation<Answer, Never>?
    func arm(picked: @escaping @Sendable () async -> Answer, reserving: @escaping @Sendable () async -> Void) {
      (self.picked, self.reserving) = (picked, reserving)
    }
    func at(_ step: RecordSender.Step) async {
      switch step {
      case .picked:
        guard let picked else { return }
        self.picked = nil
        let answer = await picked()
        made = answer
        waiter?.resume(returning: answer)
      case .reserving:
        guard picked == nil, let reserving else { return }
        self.reserving = nil
        await reserving()
      }
    }
    var answer: Answer {
      get async {
        if let made { return made }
        return await withCheckedContinuation { waiter = $0 }
      }
    }
  }

  /// 同一条连要两次、中间改过：两次都只在新版收下后答。
  @Test func askedTwiceWithAnEditBetweenIsAnsweredWithTheNewVersion() async throws {
    let server = Gated()
    let (r, R) = try await card("r1")
    let sender = await started(server)
    try await edit(r, "r2")
    let first = await ask(sender, [R])
    await server.untilCalls(1)
    try await edit(r, "r3")
    let second = await ask(sender, [R])
    await server.release(0)  // r2 收下：答不了第二次
    await server.untilCalls(2)  // r3 那一批已在路上、挂着
    #expect(await sender.waited.contains(R))
    await server.open()
    #expect(await first.value)
    #expect(await second.value)
    #expect(await server.bodies[R] == "r3")
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
