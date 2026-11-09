import CloudKit
import CueStore
import Foundation
import Synchronization
import Testing

@testable import CueSync

/// 串行：网络回来是全进程的，同一套里并行会互相叫醒。
@Suite(.serialized) struct AccountCheckTests {
  let fixture = try! Fixture()
  let cloud = ScriptedCloud()
  let accountChanges = NotificationCenter()
  var store: CueStore { fixture.store }

  @Test func 账号变了认清之前不传_途中又变就另认_旧答复不算() async throws {
    let sync = try await connected()
    let stale = Promise<Void>()
    await cloud.script(name: { n in
      guard n == 1 else { return "B" }
      try await stale.value()  // 变化之前发出的那次：答复还是原来的账号
      return "simulated"
    })
    changeAccount()
    try await eventually("在认") { await cloud.nameCalls == 1 }
    let card = try await store.createCard(body: "认清之前记的")
    #expect(await !sync.send(recordNames: [name(card)]))

    changeAccount()
    try await eventually("另认出是另一个账号") { await sync.coordinator.status == .needsDecision(.accountSwitched) }
    stale.resolve(.success(()))
    await quietPeriod(.milliseconds(200))
    #expect(await sync.coordinator.status == .needsDecision(.accountSwitched))
    #expect(await !cloud.inner.saved.contains(name(card)))
    await sync.stop()
  }

  @Test func 后一次认不清时_先发出的那次晚到的成功不放开() async throws {
    let sync = try await connected()
    let late = Promise<Void>()
    await cloud.script(name: { n in
      guard n == 1 else { throw URLError(.notConnectedToInternet) }
      try await late.value()
      return "simulated"
    })
    changeAccount()
    try await eventually("第一次在认") { await cloud.nameCalls == 1 }
    changeAccount()
    try await eventually("第二次认不清") { await sync.coordinator.state.status == .accountUnavailable }
    late.resolve(.success(()))
    await quietPeriod(.milliseconds(200))

    let card = try await store.createCard(body: "认不清时记的")
    #expect(await !sync.send(recordNames: [name(card)]))
    #expect(await sync.coordinator.state.status == .accountUnavailable)
    await sync.stop()
  }

  @Test func 比对本地账号时又变回原账号_按后一次的结论() async throws {
    let sync = try await connected()
    let answered = Promise<Void>()
    await cloud.script(name: { n in
      guard n == 1 else { return "simulated" }
      try await answered.value()
      return "B"
    })
    changeAccount()
    try await eventually("第一次在认名字") { await cloud.nameCalls == 1 }
    let hold = StoreHold()
    let blocker = Task.detached { [store] in await store.occupy(hold) }  // 占住资料库：第一次停在读本地记下的账号
    try await eventually("资料库被占住") { hold.holding.load(ordering: .relaxed) }
    answered.resolve(.success(()))
    await quietPeriod(.milliseconds(200))
    changeAccount()
    try await eventually("第二次认完名字") { await cloud.nameCalls == 2 }
    await quietPeriod(.milliseconds(200))
    hold.busy.store(false, ordering: .relaxed)
    await blocker.value

    try await eventually("放开") { await sync.coordinator.canSync }
    let card = try await store.createCard(body: "变回原账号之后记的")
    #expect(await sync.send(recordNames: [name(card)]))
    #expect(await sync.coordinator.status != .needsDecision(.accountSwitched))
    await sync.stop()
  }

  @Test func 定时再认在路上时停下_等它收尾_再开始照常连上() async throws {
    let sync = try await connected()
    await cloud.script(status: { _ in .temporarilyUnavailable })
    changeAccount()
    try await eventually("认不清、等再认") { await sync.coordinator.state.status == .accountUnavailable }
    let hung = Promise<Void>()
    await cloud.script(status: { _ in
      try await hung.value()
      return .available
    })
    try await eventually("到点再认，请求挂住") { await cloud.inFlight == 1 }

    await sync.stop()
    try await eventually("挂着的请求被取消") { await cloud.inFlight == 0 }
    hung.resolve(.success(()))
    await cloud.script()
    await sync.start()
    let card = try await store.createCard(body: "再开始之后记的")
    #expect(await sync.send(recordNames: [name(card)]))
    await sync.stop()
  }

  /// 不等账号那条的退避：离线久了它长到几分钟。
  @Test func 认不了账号时网络回来_当场再认() async throws {
    await cloud.script(status: { _ in throw URLError(.notConnectedToInternet) })
    let sync = make()
    await sync.start()
    for _ in 0..<8 { await sync.recheckNow() }  // 连着失败几次，退避长过这个测试能等的
    await cloud.script()

    NetworkReturns.simulateReturn()
    try await eventually("网络回来就再认、连上") { try await sync.syncNow() != .incomplete }
    await sync.stop()
  }

  @Test func 停在要你决定时_立即同步不再认账号() async throws {
    await rememberAccount()
    await cloud.script(name: { _ in "B" })
    let sync = make()
    await sync.start()
    #expect(await sync.coordinator.status == .needsDecision(.accountSwitched))
    for _ in 0..<5 { #expect(try await sync.syncNow() == .incomplete) }
    #expect(await cloud.statusCalls == 1)
    await sync.stop()
  }

  /// 不等请求到时限（`RequestLimits.request`）：iOS 后台刷新到期就取消它。
  @Test func 认账号没有回音时取消立即同步_当场返回() async throws {
    await cloud.script(status: { _ in
      try await Task.sleep(for: .seconds(3600))
      return .available
    })
    let sync = make()
    let starting = Task { await sync.start() }
    try await eventually("在认") { await cloud.statusCalls == 1 }
    let pulling = Task { try await sync.syncNow() }
    await quietPeriod(.milliseconds(100))
    let began = ContinuousClock.now
    pulling.cancel()
    _ = await pulling.result
    #expect(ContinuousClock.now - began < RequestLimits.request / 3)
    await sync.stop()
    await starting.value
  }

  private func connected() async throws -> CloudSync {
    await rememberAccount()
    let sync = make()
    await sync.start()
    #expect(await sync.connected)
    await cloud.script()
    return sync
  }

  private func rememberAccount() async {
    let first = make()
    await first.start()
    await first.stop()
  }

  private func changeAccount() { accountChanges.post(name: .CKAccountChanged, object: nil) }

  private func make() -> CloudSync { CloudSync(store: store, accountChanges: accountChanges) { [cloud] in cloud } }

  private func name(_ card: Card) -> String { card.id.uuidString.lowercased() }
}

extension CloudSync {
  fileprivate func recheckNow() async {
    guard let generation = running?.generation else { return }
    recheck(generation)
    _ = await running?.checking?.value
  }
}

final class StoreHold: Sendable {
  let busy = Atomic(true), holding = Atomic(false)
}

extension CueStore {
  /// 在资料库自己的队列上等到放开：排在它后面的读写都等着。
  fileprivate func occupy(_ hold: StoreHold) {
    hold.holding.store(true, ordering: .relaxed)
    while hold.busy.load(ordering: .relaxed) { usleep(1000) }
  }
}

actor ScriptedCloud: SyncCloud {
  let inner: SimulatedCloud
  private(set) var statusCalls = 0
  private(set) var nameCalls = 0
  private(set) var inFlight = 0
  private var status: (@Sendable (Int) async throws -> CKAccountStatus)?
  private var name: (@Sendable (Int) async throws -> String)?

  init() {
    let floor = CKRecord(recordType: PeerFloor.recordType, recordID: PeerFloor(zoneID: CloudSync.zoneID).id)
    floor[PeerFloor.field] = CueStore.peerFloor as NSNumber
    inner = SimulatedCloud([floor])
  }

  /// 之后的答复（nil：交给替身），次数从头数。
  func script(status: (@Sendable (Int) async throws -> CKAccountStatus)? = nil, name: (@Sendable (Int) async throws -> String)? = nil) {
    (self.status, self.name, statusCalls, nameCalls) = (status, name, 0, 0)
  }

  func accountStatus() async throws -> CKAccountStatus {
    statusCalls += 1
    inFlight += 1
    defer { inFlight -= 1 }
    guard let status else { return await inner.accountStatus() }
    return try await status(statusCalls)
  }

  func accountName() async throws -> String {
    nameCalls += 1
    guard let name else { return await inner.accountName() }
    return try await name(nameCalls)
  }

  func relaySecret() async throws -> Data { await inner.relaySecret() }
  func diagnosticChanges(since token: Data?) async throws -> ZoneChangeBatch { try await inner.diagnosticChanges(since: token) }
  func uploadDiagnostics(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> SentRecords {
    await inner.uploadDiagnostics(saving: saving, deleting: deleting)
  }
  func changes(since token: Data?, keys: [String]) async throws -> ZoneChangeBatch { await inner.changes(since: token, keys: keys) }
  func records(_ ids: [CKRecord.ID]) async throws -> [CKRecord] { await inner.records(ids) }
  func upload(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> SentRecords { await inner.upload(saving: saving, deleting: deleting) }
  func uploadFile(_ record: CKRecord, progress: @escaping @Sendable (Double) -> Void) async throws -> SentRecords {
    await inner.uploadFile(record, progress: progress)
  }
  func resumedFileUploads() async throws -> [ResumedUpload] { [] }
  func downloadFile(_ id: CKRecord.ID, progress: @escaping @Sendable (Double) -> Void) async throws -> CKRecord? {
    await inner.downloadFile(id, progress: progress)
  }
  func saveZone() async throws {}
  func subscriptions() async throws -> [CKSubscription.ID: CKSubscription] { [:] }
  func save(_ subscription: CKSubscription) async throws {}
  func delete(_ id: CKSubscription.ID) async throws {}
}
