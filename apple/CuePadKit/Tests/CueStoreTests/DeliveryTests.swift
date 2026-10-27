import CueStore
import Foundation
import Testing

/// 投送请求：手机写内容与目标；Mac 执行（经回调交给 App 层）后写回结果；完成后清理。
@Suite struct DeliveryTests {
  let fixture = try! Fixture()
  let clock = ManualTiming()
  var store: CueStore { fixture.store }

  private let pi = SendTarget(kind: .piSession, name: "fix bug", ref: "s1")

  /// 记录被调用的请求；可控制何时返回。
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
    DeliveryExecutor(store: store, hostID: "mac-a", timing: clock.timing, onIssue: { Issue.record("执行器意外上报：\($0)") }) {
      await handler.handle($0)
    }
  }

  private func request(_ id: UUID) async throws -> DeliveryRequest? { try await store.deliveryRequest(id) }

  /// 交给上传的每一版：`onWritten` 被调那一刻库里这条请求的状态（马上传读的就是那一刻的行）。
  actor Uploads {
    private(set) var statuses: [DeliveryStatus?] = []
    func add(_ status: DeliveryStatus?) { statuses.append(status) }
  }

  private func executor(_ uploads: Uploads, handler: @escaping @Sendable (DeliveryRequest) async -> DeliveryOutcome) -> DeliveryExecutor {
    DeliveryExecutor(
      store: store, hostID: "mac-a", timing: clock.timing, onIssue: { Issue.record("执行器意外上报：\($0)") },
      onWritten: { [store] id in await uploads.add(try? await store.deliveryRequest(id)?.status.known) }, handler: handler)
  }

  /// 当场执行完的只交出结果那一版：领取那一版在路上时结果得等它回来才能传，手机的回执要多等一个来回。
  @Test
  func aRequestFinishedRightAwayHandsOnlyTheResultToUpload() async throws {
    let uploads = Uploads()
    let executor = executor(uploads) { _ in .succeeded }
    try await executor.start()
    _ = try await store.requestDelivery("hi", to: pi, on: "mac-a")
    try await eventually("结果交给上传") { await !uploads.statuses.isEmpty }
    clock.advance(DeliveryExecutor.claimGrace)
    try await Task.sleep(for: .milliseconds(100))  // 领取那次要是没取消，到点后会在这段里交出

    #expect(await uploads.statuses == [.succeeded])
    await executor.stop()
  }

  /// 执行得久的（唤醒已结束的会话）到 `claimGrace` 先交出领取那一版：手机据它知道 Mac 接手了，不会报成没送到。
  @Test
  func aLongRunningRequestHandsOverTheClaimFirstThenTheResult() async throws {
    let uploads = Uploads()
    let (gate, open) = AsyncStream<Void>.makeStream()
    let executor = executor(uploads) { _ in
      for await _ in gate {}
      return .succeeded
    }
    try await executor.start()
    _ = try await store.requestDelivery("唤醒会话", to: pi, on: "mac-a")
    await clock.waitForSleeper()
    clock.advance(DeliveryExecutor.claimGrace)
    try await eventually("领取交给上传") { await !uploads.statuses.isEmpty }
    #expect(await uploads.statuses == [.executing])

    open.finish()
    try await eventually("结果交给上传") { await uploads.statuses.count == 2 }
    #expect(await uploads.statuses == [.executing, .succeeded])
    await executor.stop()
  }

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

  /// 发出的话到期清理不带走：没能送达的等用户重发或移除，送到的等它的消息上了服务器再收走（见 `DeviceFlowTests`），别的完成请求照常清理。
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

    await clock.waitForSleeper()
    clock.advance(DeliveryExecutor.retention + .seconds(1))
    let remaining = try await eventually(store, { try $0.deliveryRequests() }) { $0.count == 2 }
    #expect(Set(remaining.map(\.id)) == [failed.id, sent.id])
    await executor.stop()
  }

  @Test func requestInterruptedByAnAppRestartFailsAndIsNeverRunAgain() async throws {
    let handler = Handler()
    let stuck = try await store.requestDelivery("half done", to: pi, on: "mac-a")
    try RawDB(fixture.url).exec("UPDATE deliveryRequests SET status = 'executing', handledBy = 'mac-a'")

    let executor = executor(handler)
    try await executor.start()

    let after = try #require(try await request(stuck.id))
    #expect(after.status == .known(.failed) && after.failureReason?.text.isEmpty == false)
    #expect(await handler.seen.isEmpty)  // 不重发：可能已经发出去了一半
    await executor.stop()
  }

  @Test
  func requestsOlderThanTheMaximumAgeAreAbandonedInsteadOfSurprisingTheUser() async throws {
    let handler = Handler()
    let stale = try await store.requestDelivery("old prompt", to: pi, on: "mac-a")
    // 一天前写下的请求：比任何最长等待都旧
    try RawDB(fixture.url).exec("UPDATE deliveryRequests SET createdAt = createdAt - 86400000")

    let executor = executor(handler)
    try await executor.start()

    _ = try await eventually(store, { try $0.deliveryRequests().first?.status }) { $0 == .known(.failed) }
    let after = try #require(try await request(stale.id))
    #expect(after.failureReason?.text.isEmpty == false)
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
    #expect(done[0].failureReason?.text.contains("quantumSend") == true)
    #expect(done[0].mode == .unknown("quantumSend") && done[0].completedAt != nil)
    await executor.stop()
  }

}
