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

  /// 发出的话到期清理不带走：没能送达的等用户重发或移除，送到的等它进了对话再随之收走，气泡不会两头都不在（别的完成请求照常清理）。
  @Test
  func sentMessagesStayUntilTheyReachTheConversationOrTheUserRemovesThem() async throws {
    let handler = Handler()
    await handler.setOutcome(.failed("Pi 已经退出"))
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

    let said = PiChatMessage(sessionID: "s", entryID: "u0", seq: 0, role: .user, text: sent.content, at: .now, deliveryID: sent.id)
    try await store.writePiTranscript(PiTranscript(sessionID: "s", messages: [said], recap: PiRecap()))
    #expect(try await store.deliveryRequests().map(\.id) == [failed.id])
    #expect(try await store.latest(of: sent)?.status == .known(.succeeded))
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
    #expect(after.resultDetail?.isEmpty == false)
    #expect(await handler.seen.isEmpty)
    await executor.stop()
  }

  @Test
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
    _ = try await eventually(store, { try $0.deliveryRequests().filter { $0.status == .known(.succeeded) }.count }) { $0 == 1 }
    #expect(try await store.deliveryRequest(waiting.id)?.status == .known(.pending))

    // 图片同步到了：文件放进附件目录，附件记录随后应用
    _ = try store.files.store(data)
    let arrived: [String: SQLValue] = [
      "id": .text(UUID().uuidString.lowercased()), "hash": .text(hash), "byteCount": .int(Int64(data.count)),
      "format": .text("png"), "createdAt": .int(1), "modifiedAt": .int(1),
    ]
    _ = try await store.applyRemote([.save(SyncRow(table: .attachments, fields: arrived), systemFields: Data())])

    _ = try await eventually(store, { try $0.deliveryRequests().filter { $0.status == .known(.succeeded) }.count }) { $0 == 2 }
    #expect(await runs.entries.map(\.name) == ["plain", "look"])
    #expect(await runs.entries.last?.imagePresent == true)  // 执行时图片已经在本机
    await executor.stop()
  }

  actor RunLog {
    struct Entry: Sendable { var name: String; var imagePresent: Bool }
    private(set) var entries: [Entry] = []
    func record(_ name: String, imagePresent: Bool) { entries.append(Entry(name: name, imagePresent: imagePresent)) }
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
    #expect(done[0].resultDetail?.contains("quantumSend") == true)
    #expect(done[0].mode == .unknown("quantumSend") && done[0].completedAt != nil)
    await executor.stop()
  }

}
