import CueStore
import Foundation
import Testing

@Suite struct DeliveryTests {
  let fixture = try! Fixture()
  let clock = ManualTiming()
  var store: CueStore { fixture.store }

  private let pi = SendTarget(kind: .piSession, name: "fix bug", ref: "s1")

  actor Handler {
    private(set) var seen: [DeliveryRequest] = []
    private(set) var concurrent = 0
    private(set) var maxConcurrent = 0
    var outcome: DeliveryOutcome = .succeeded
    func setOutcome(_ value: DeliveryOutcome) { outcome = value }
    func handle(_ request: DeliveryRequest) async -> DeliveryOutcome {
      concurrent += 1
      maxConcurrent = max(maxConcurrent, concurrent)
      seen.append(request)
      await Task.yield()
      concurrent -= 1
      return outcome
    }
  }

  private func executor(_ handler: Handler) -> DeliveryExecutor {
    DeliveryExecutor(store: store, hostID: "mac-a", timing: clock.timing, onIssue: { Issue.record("执行器意外上报：\($0)") }) { request, _ in
      await handler.handle(request)
    }
  }

  private func request(_ id: UUID) async throws -> DeliveryRequest? { try await store.deliveryRequest(id) }

  @Test
  func requestsAreExecutedOneAtATimeInCreationOrder() async throws {
    let handler = Handler()
    let executor = executor(handler)
    try await executor.start()
    for index in 0..<4 {
      _ = try await store.requestDelivery("r\(index)", to: pi, on: "mac-a")
      clock.advance(.milliseconds(5))
    }
    _ = try await eventually(store, { try $0.deliveryRequests().filter { $0.status == .known(.succeeded) }.count }) { $0 == 4 }

    #expect(await handler.seen.map(\.content) == ["r0", "r1", "r2", "r3"])
    #expect(await handler.maxConcurrent == 1)
    await executor.stop()
  }

  @Test
  func sentMessagesOutliveTheRetention() async throws {
    let handler = Handler()
    await handler.setOutcome(.failed(.verbatim("Pi 已经退出")))
    let executor = executor(handler)
    try await executor.start()
    let failed = try await store.requestDelivery("备份一下线上库", to: pi, on: "mac-a", mode: .send)
    _ = try await eventually(store, { try $0.deliveryRequest(failed.id)?.status }) { $0 == .known(.failed) }
    await handler.setOutcome(.succeeded)
    let sent = try await store.requestDelivery("跑一遍测试", to: pi, on: "mac-a", mode: .send)
    _ = try await store.requestDelivery("quota", to: pi, on: "mac-a", mode: .quota)
    _ = try await eventually(store, { try $0.deliveryRequests().filter { $0.status == .known(.succeeded) }.count }) { $0 == 2 }

    try await clock.waitForSleeper(until: clock.now.addingTimeInterval(DeliveryExecutor.retention.seconds))
    clock.advance(DeliveryExecutor.retention + .seconds(1))
    let remaining = try await eventually(store, { try $0.deliveryRequests() }) { $0.count == 2 }
    #expect(Set(remaining.map(\.id)) == [failed.id, sent.id])
    await executor.stop()
  }

  @Test
  func requestsOlderThanTheMaximumAgeAreAbandonedInsteadOfSurprisingTheUser() async throws {
    let handler = Handler()
    let stale = try await store.requestDelivery("old prompt", to: pi, on: "mac-a")
    try RawDB(fixture.url).exec("UPDATE deliveryRequests SET createdAt = createdAt - 86400000")

    let executor = executor(handler)
    try await executor.start()

    _ = try await eventually(store, { try $0.deliveryRequests().first?.status }) { $0 == .known(.failed) }
    let after = try #require(try await request(stale.id))
    #expect(after.reason?.text.isEmpty == false)
    #expect(await handler.seen.isEmpty)
    await executor.stop()
  }

  @Test
  func aModeFromANewerVersionIsKeptButNeverExecutedAndFailsWithAReason() async throws {
    let handler = Handler()
    let made = try await store.requestDelivery("x", to: pi, on: "mac-a")
    try RawDB(fixture.url).exec("UPDATE deliveryRequests SET mode = 'quantumSend'")
    #expect(try await request(made.id)?.mode == .unknown("quantumSend"))  // 原样保留

    let executor = executor(handler)
    try await executor.start()
    let done = try await eventually(store, { try $0.deliveryRequests() }) { $0.first?.status == .known(.failed) }

    #expect(await handler.seen.isEmpty)  // 不认识的发送方式不执行，也不猜成 send
    #expect(done[0].reason?.text.contains("quantumSend") == true)
    #expect(done[0].mode == .unknown("quantumSend") && done[0].completedAt != nil)
    await executor.stop()
  }

}
