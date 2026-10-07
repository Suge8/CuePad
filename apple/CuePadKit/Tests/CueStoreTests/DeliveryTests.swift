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

  private func executor(
    _ handler: Handler, host: String = "mac-a", maxAge: Duration = .seconds(600), retention: Duration = .seconds(60)
  ) -> DeliveryExecutor {
    DeliveryExecutor(
      store: store, hostID: host, maxAge: maxAge, retention: retention, timing: clock.timing,
      onIssue: { Issue.record("执行器意外上报：\($0)") }
    ) { await handler.handle($0) }
  }

  private func request(_ id: UUID) async throws -> DeliveryRequest? { try await store.deliveryRequest(id) }

  /// 结果没能写回时手机会一直等：执行器必须上报，不能吞掉。
  @Test(.timeLimit(.minutes(1)))
  func failureToWriteTheResultBackIsReported() async throws {
    try RawDB(fixture.url).exec(
      """
      CREATE TRIGGER refuseResult BEFORE UPDATE OF status ON deliveryRequests WHEN new.status = 'succeeded'
      BEGIN SELECT RAISE(ABORT, 'disk said no'); END;
      """)
    let (issues, reported) = AsyncStream<String>.makeStream()
    let executor = DeliveryExecutor(store: store, hostID: "mac-a", timing: clock.timing, onIssue: { reported.yield("\($0)") }) { _ in
      .succeeded
    }
    try await executor.start()
    _ = try await store.requestDelivery("do it", to: pi, on: "mac-a")

    var iterator = issues.makeAsyncIterator()
    #expect(await iterator.next()?.contains("disk said no") == true)
    await executor.stop()
  }

  @Test func requestIsRecordedAsPendingWithContentAndTarget() async throws {
    let card = try await store.createCard(in: nil, body: "c")
    let made = try await store.requestDelivery("prompt", to: pi, on: "mac-a", mode: .followUp, card: card.id)

    let stored = try #require(try await request(made.id))
    #expect(stored.status == .known(.pending) && stored.content == "prompt" && stored.target == pi)
    #expect(stored.hostID == "mac-a" && stored.mode == .known(.followUp) && stored.cardID == card.id)
    #expect(stored.completedAt == nil && stored.resultDetail == nil)
    await #expect(throws: CueStoreError.blankDeliveryContent) { try await store.requestDelivery("  ", to: pi, on: "mac-a") }
  }

  @Test(.timeLimit(.minutes(1)))
  func executorRunsTheHandlerAndWritesTheResultBack() async throws {
    let handler = Handler()
    let executor = executor(handler)
    try await executor.start()
    let made = try await store.requestDelivery("do it", to: pi, on: "mac-a")

    let done = try await eventually(store, watching: [.deliveryRequests], { try $0.deliveryRequests() }) { $0.first?.status == .known(.succeeded) }

    #expect(done[0].id == made.id && done[0].handledBy == "mac-a" && done[0].completedAt == clock.now)
    #expect(await handler.seen.map(\.content) == ["do it"])
    await executor.stop()
  }

  @Test(.timeLimit(.minutes(1)))
  func failureIsWrittenBackWithItsReason() async throws {
    let handler = Handler()
    await handler.setOutcome(.failed("会话已结束"))
    let executor = executor(handler)
    try await executor.start()
    _ = try await store.requestDelivery("x", to: pi, on: "mac-a")

    let done = try await eventually(store, watching: [.deliveryRequests], { try $0.deliveryRequests() }) { $0.first?.status == .known(.failed) }
    #expect(done[0].resultDetail == "会话已结束")
    await executor.stop()
  }

  /// 请求必须指定执行的 Mac，执行器只领取发给本机的：跨设备重复在结构上不会发生。
  @Test(.timeLimit(.minutes(1)))
  func onlyRequestsAddressedToThisHostAreExecuted() async throws {
    let handler = Handler()
    let executor = executor(handler, host: "mac-a")
    let other = try await store.requestDelivery("for b", to: pi, on: "mac-b")
    let mine = try await store.requestDelivery("for a", to: pi, on: "mac-a")
    try await executor.start()

    _ = try await eventually(store, watching: [.deliveryRequests], { try $0.deliveryRequests().filter { $0.status == .known(.succeeded) }.count }) { $0 == 1 }

    #expect(await handler.seen.map(\.id) == [mine.id])
    #expect(try await request(other.id)?.status == .known(.pending))
    await executor.stop()
  }

  @Test(.timeLimit(.minutes(1)))
  func requestsAreExecutedOneAtATimeInCreationOrder() async throws {
    let handler = Handler()
    let executor = executor(handler)
    try await executor.start()
    for index in 0..<4 {
      _ = try await store.requestDelivery("r\(index)", to: pi, on: "mac-a")
      clock.advance(.milliseconds(5))
    }
    _ = try await eventually(store, watching: [.deliveryRequests], { try $0.deliveryRequests().filter { $0.status == .known(.succeeded) }.count }) { $0 == 4 }

    #expect(await handler.seen.map(\.content) == ["r0", "r1", "r2", "r3"])
    #expect(await handler.maxConcurrent == 1)
    await executor.stop()
  }

  @Test(.timeLimit(.minutes(1)))
  func completedRequestsAreCleanedUpAfterTheRetentionButOpenOnesStay() async throws {
    let handler = Handler()
    let executor = executor(handler, retention: .seconds(60))
    let open = try await store.requestDelivery("other host", to: pi, on: "mac-b")
    try await executor.start()
    _ = try await store.requestDelivery("finished", to: pi, on: "mac-a")
    _ = try await eventually(store, watching: [.deliveryRequests], { try $0.deliveryRequests().filter { $0.status == .known(.succeeded) }.count }) { $0 == 1 }

    await clock.waitForSleeper()
    clock.advance(.seconds(61))
    let remaining = try await eventually(store, watching: [.deliveryRequests], { try $0.deliveryRequests() }) { $0.count == 1 }

    #expect(remaining.map(\.id) == [open.id])
    await executor.stop()
  }

  @Test func requestInterruptedByAnAppRestartFailsAndIsNeverRunAgain() async throws {
    let handler = Handler()
    let stuck = try await store.requestDelivery("half done", to: pi, on: "mac-a")
    try RawDB(fixture.url).exec("UPDATE deliveryRequests SET status = 'executing', handledBy = 'mac-a'")

    let executor = executor(handler)
    try await executor.start()

    let after = try #require(try await request(stuck.id))
    #expect(after.status == .known(.failed) && after.resultDetail?.isEmpty == false)
    #expect(await handler.seen.isEmpty)  // 不重发：可能已经发出去了一半
    await executor.stop()
  }

  @Test(.timeLimit(.minutes(1)))
  func requestsOlderThanTheMaximumAgeAreAbandonedInsteadOfSurprisingTheUser() async throws {
    let handler = Handler()
    let stale = try await store.requestDelivery("old prompt", to: pi, on: "mac-a")
    clock.advance(.seconds(601))
    // 请求的创建时间来自真实时钟：让它落到"过去"
    try RawDB(fixture.url).exec("UPDATE deliveryRequests SET createdAt = createdAt - 700000")

    let executor = executor(handler, maxAge: .seconds(600))
    try await executor.start()

    _ = try await eventually(store, watching: [.deliveryRequests], { try $0.deliveryRequests().first?.status }) { $0 == .known(.failed) }
    let after = try #require(try await request(stale.id))
    #expect(after.resultDetail?.isEmpty == false)
    #expect(await handler.seen.isEmpty)
    await executor.stop()
  }

  @Test(.timeLimit(.minutes(1)))
  func requestWaitsForItsImagesToArriveThenRunsAfterOtherRequests() async throws {
    let data = pngData(width: 6, height: 6)
    let elsewhere = try Fixture()  // 图片在另一台设备上，尚未同步到本机
    let hash = try elsewhere.store.files.store(data)
    let store = store
    let runs = RunLog()
    let executor = DeliveryExecutor(
      store: store, hostID: "mac-a", timing: clock.timing, onIssue: { Issue.record("执行器意外上报：\($0)") }
    ) { request in
      await runs.record(request.content.hasPrefix("look") ? "look" : request.content, imagePresent: store.files.fileURL(for: hash) != nil)
      return .succeeded
    }
    try await executor.start()
    let waiting = try await store.requestDelivery("look ![](cuepad://img/\(hash))", to: pi, on: "mac-a")
    _ = try await store.requestDelivery("plain", to: pi, on: "mac-a")

    // 排在后面的普通请求先执行，说明前面那条被跳过而不是抢跑
    _ = try await eventually(store, watching: [.deliveryRequests], { try $0.deliveryRequests().filter { $0.status == .known(.succeeded) }.count }) { $0 == 1 }
    #expect(try await store.deliveryRequest(waiting.id)?.status == .known(.pending))

    // 图片同步到了：文件放进附件目录，附件记录随后应用
    _ = try store.files.store(data)
    let arrived: [String: SQLValue] = [
      "id": .text(UUID().uuidString.lowercased()), "hash": .text(hash), "byteCount": .int(Int64(data.count)),
      "format": .text("png"), "createdAt": .int(1), "modifiedAt": .int(1),
    ]
    _ = try await store.applyRemote([.save(SyncRow(table: .attachments, fields: arrived), systemFields: Data())])

    _ = try await eventually(store, watching: [.deliveryRequests], { try $0.deliveryRequests().filter { $0.status == .known(.succeeded) }.count }) { $0 == 2 }
    #expect(await runs.entries.map(\.name) == ["plain", "look"])
    #expect(await runs.entries.last?.imagePresent == true)  // 执行时图片已经在本机
    await executor.stop()
  }

  actor RunLog {
    struct Entry: Sendable { var name: String; var imagePresent: Bool }
    private(set) var entries: [Entry] = []
    func record(_ name: String, imagePresent: Bool) { entries.append(Entry(name: name, imagePresent: imagePresent)) }
  }

  @Test(.timeLimit(.minutes(1)))
  func twoExecutorsNeverRunTheSameRequestTwice() async throws {
    let first = Handler()
    let second = Handler()
    let one = executor(first)
    let two = executor(second)
    try await one.start()
    try await two.start()
    for index in 0..<6 { _ = try await store.requestDelivery("r\(index)", to: pi, on: "mac-a") }

    _ = try await eventually(store, watching: [.deliveryRequests], { try $0.deliveryRequests().filter { $0.status == .known(.succeeded) }.count }) { $0 == 6 }

    let all = await first.seen.map(\.id) + second.seen.map(\.id)
    #expect(all.count == 6 && Set(all).count == 6)  // 领取是原子的
    await one.stop()
    await two.stop()
  }

  @Test(.timeLimit(.minutes(1)))
  func everyKnownModeReachesTheHandlerAsItsTypedValue() async throws {
    let handler = Handler()
    let executor = executor(handler)
    try await executor.start()
    let modes: [DeliveryMode] = [.send, .steer, .followUp, .paste]
    for mode in modes { _ = try await store.requestDelivery("m", to: pi, on: "mac-a", mode: mode) }

    _ = try await eventually(store, watching: [.deliveryRequests], { try $0.deliveryRequests().filter { $0.status == .known(.succeeded) }.count }) { $0 == 4 }

    #expect(await handler.seen.map(\.mode) == modes.map(Open.known))
    #expect(modes.map(\.rawValue) == ["send", "steer", "followUp", "paste"])  // 落盘与线上的字面值
    await executor.stop()
  }

  @Test(.timeLimit(.minutes(1)))
  func aModeFromANewerVersionIsKeptButNeverExecutedAndFailsWithAReason() async throws {
    let handler = Handler()
    let made = try await store.requestDelivery("x", to: pi, on: "mac-a")
    try RawDB(fixture.url).exec("UPDATE deliveryRequests SET mode = 'quantumSend'")
    #expect(try await request(made.id)?.mode == .unknown("quantumSend"))  // 原样保留

    let executor = executor(handler)
    try await executor.start()
    let done = try await eventually(store, watching: [.deliveryRequests], { try $0.deliveryRequests() }) { $0.first?.status == .known(.failed) }

    #expect(await handler.seen.isEmpty)  // 不认识的发送方式不执行，也不猜成 send
    #expect(done[0].resultDetail?.contains("quantumSend") == true)
    #expect(done[0].mode == .unknown("quantumSend") && done[0].completedAt != nil)
    await executor.stop()
  }

  @Test func unknownStatusFromANewerVersionIsPreserved() async throws {
    let made = try await store.requestDelivery("x", to: pi, on: "mac-a")
    try RawDB(fixture.url).exec("UPDATE deliveryRequests SET status = 'queuedRemotely'")
    #expect(try await request(made.id)?.status == .unknown("queuedRemotely"))
  }

  /// 配置请求（换模型、改思考强度）与发送同一条投送通道：正文是 JSON，读回来是同一个配置；什么都不改或强度不认识的读不出。
  @Test func configRequestCarriesTheModelAndThinkingToTheMacAndIsNotAMessageToTheSession() async throws {
    let config = PiConfig(model: PiModelKey(provider: "anthropic", id: "opus"), thinking: .high)
    let made = try await store.requestConfig(config, to: pi, on: "mac-a")

    let stored = try #require(try await request(made.id))
    #expect(stored.mode == .known(.config) && stored.hostID == "mac-a" && stored.config == config)
    #expect(DeliveryMode.config.rawValue == "config")
    #expect(try await store.requestDelivery(#"{"thinking":"ultra"}"#, to: pi, on: "mac-a", mode: .config).config == nil)
    #expect(try await store.requestDelivery("{}", to: pi, on: "mac-a", mode: .config).config == nil)
    #expect(!DeliveryMode.toSession.contains(.config))  // 不是对会话说的话：会话页不把它当最近一条消息
  }

  /// 结束会话请求与发送同一条投送通道；它让会话停下，不是对会话说的话。
  @Test func endRequestIsAddressedToTheSessionsMacAndIsNotAMessageToIt() async throws {
    let made = try await store.requestEnd(of: pi, on: "mac-a")

    let stored = try #require(try await request(made.id))
    #expect(stored.mode == .known(.end) && stored.hostID == "mac-a" && stored.target == pi && stored.isOpen)
    #expect(DeliveryMode.end.rawValue == "end")
    #expect(!DeliveryMode.toSession.contains(.end))
  }
}
