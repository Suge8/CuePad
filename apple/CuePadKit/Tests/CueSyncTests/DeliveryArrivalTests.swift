import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

/// Mac 上的主动拉取是别的设备写来的请求到达的主通路：请求一经拉到，执行器必须马上领取并执行，
/// 执行器正忙于上一条时新来的也不能被漏掉或拖着。
@Suite struct DeliveryArrivalTests {
  private static let target = SendTarget(kind: .piSession, name: "video", ref: "s1")
  private static let promptly: Duration = .seconds(1)

  let mac = try! Rig()
  let phone = try! Rig()

  /// 记下被交给 App 层的请求；第一条可以挂起，直到放行。
  actor Handler {
    private(set) var seen: [UUID] = []
    private var gate: CheckedContinuation<Void, Never>?
    private let holdsFirst: Bool
    private let started: AsyncStream<UUID>.Continuation

    init(holdsFirst: Bool, started: AsyncStream<UUID>.Continuation) {
      self.holdsFirst = holdsFirst
      self.started = started
    }

    func handle(_ request: DeliveryRequest) async -> DeliveryOutcome {
      seen.append(request.id)
      started.yield(request.id)
      if holdsFirst, seen.count == 1 { await withCheckedContinuation { gate = $0 } }
      return .succeeded
    }

    func release() { gate?.resume(); gate = nil }
  }

  private func start(holdingFirst: Bool = false) async throws -> (executor: DeliveryExecutor, handler: Handler, started: AsyncStream<UUID>) {
    let (started, continuation) = AsyncStream.makeStream(of: UUID.self)
    let handler = Handler(holdsFirst: holdingFirst, started: continuation)
    let executor = DeliveryExecutor(store: mac.store, hostID: "mac", onIssue: { Issue.record("执行器意外上报：\($0)") }) { await handler.handle($0) }
    try await executor.start()
    return (executor, handler, started)
  }

  /// 手机写一条发给 "mac" 的请求，取出它上传时的服务器记录。
  private func sentByPhone(_ content: String) async throws -> (id: UUID, record: CKRecord) {
    let made = try await phone.store.requestDelivery(content, to: Self.target, on: "mac")
    return (made.id, try #require(await phone.coordinator.record(for: phone.recordID(made.id))))
  }

  private func batch(_ token: String, _ records: [CKRecord] = []) -> Result<ZoneChangeBatch, any Error> {
    .success(ZoneChangeBatch(modifications: records, deletions: [], token: Data(token.utf8), moreComing: false))
  }

  private func finished(_ id: UUID) async throws {
    _ = try await eventually(mac.store, { try $0.deliveryRequest(id)?.status }) { $0 == .known(.succeeded) }
  }

  @Test(.timeLimit(.minutes(1)))
  func aRequestPulledForThisMacIsExecutedWithinASecond() async throws {
    let (executor, handler, _) = try await start()
    let (id, record) = try await sentByPhone("继续")
    let puller = ZoneChangePuller(source: FakeZone([batch("t1"), batch("t2", [record])]), coordinator: mac.coordinator)

    let began = ContinuousClock.now
    try await puller.pull()
    try await finished(id)

    #expect(ContinuousClock.now - began < Self.promptly)
    #expect(await handler.seen == [id])
    await executor.stop()
  }

  @Test(.timeLimit(.minutes(1)))
  func aRequestPulledWhileThePreviousOneIsRunningIsExecutedRightAfterIt() async throws {
    let (executor, handler, started) = try await start(holdingFirst: true)
    let (first, firstRecord) = try await sentByPhone("第一条")
    let (second, secondRecord) = try await sentByPhone("第二条")
    let puller = ZoneChangePuller(
      source: FakeZone([batch("t1"), batch("t2", [firstRecord]), batch("t3", [secondRecord])]), coordinator: mac.coordinator)

    try await puller.pull()
    var running = started.makeAsyncIterator()
    #expect(await running.next() == first)  // 第一条在执行中，被挂住
    try await puller.pull()
    _ = try await eventually(mac.store, { try $0.deliveryRequest(second)?.status }) { $0 == .known(.pending) }  // 第二条已到本机，排着

    let released = ContinuousClock.now
    await handler.release()
    try await finished(second)

    #expect(ContinuousClock.now - released < Self.promptly)
    #expect(await handler.seen == [first, second])
    await executor.stop()
  }
}
