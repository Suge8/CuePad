import CloudKit
import Foundation
import os

/// 需要 App 带 iCloud（CloudKit）entitlement 与容器；没有 entitlement 的进程（命令行测试）不能调用 `start()`。
/// `start()` 认账号并开始上传，第一次拉由 App 发起（`syncNow`，它等得到拉完）；状态为 `.needsDecision` 时让用户选择后调用 `resolve(_:)`。
///
/// 冷启动：认过账号就能拉，第一拉不等别的；最低对端版本（`PeerFloor`）由发送者在第一次上传前对，拉取不等它（拉到的页里有门槛就当场看，`SyncCoordinator.meet`）。
///
/// 不用 CKSyncEngine：它的手动拉取只在收到过推送、知道哪个区有变化时才真的发请求（macOS 27.2 实测：全新状态的第一次之后，
/// 没收到推送就原地返回，有没有推送权限、限定区、带旧状态重启都一样），而 Mac 不收推送；它的待办队列又是库里推导的待推送之外的第二份事实。
/// 拉：令牌只有库里一份，什么时候拉由 App 定。
/// 推：库里推导的待推送是唯一队列，同一条记录同一时刻只在一批里。
public actor CloudSync {
  private static let containerIdentifier = AppIdentity.iCloudContainer
  static let zoneID = CKRecordZone.ID(zoneName: "CuePad", ownerName: CKCurrentUserDefaultName)
  let coordinator: SyncCoordinator
  /// 连上 iCloud（`SyncCloud`）：`start()` 里才连，没有 entitlement 的进程一建容器就崩。
  private let connect: @Sendable () -> any SyncCloud
  private let accountChanges: NotificationCenter
  enum Phase {
    case idle
    case running(Run)
    case resolving
    case stopped
  }
  var phase = Phase.idle
  private let transfers = TransferBoard()
  private var stopping: Task<Void, Never>?
  private var startWaiters: [Promise<Bool>] = []
  let accountChecks = Broadcast<Void>(bufferingPolicy: .bufferingNewest(1))
  static let alertRetryInterval = Duration.seconds(60)
  static let log = Logger(subsystem: AppIdentity.id, category: "sync")

  #if os(iOS)
  static let subscribesToAlerts = true
  #else
  static let subscribesToAlerts = false
  #endif

  public init(store: CueStore) {
    self.init(store: store) { CloudDatabase(container: CKContainer(identifier: Self.containerIdentifier), zoneID: Self.zoneID) }
  }

  init(store: CueStore, accountChanges: NotificationCenter = .default, connect: @escaping @Sendable () -> any SyncCloud) {
    coordinator = SyncCoordinator(store: store, zoneID: Self.zoneID)
    self.accountChanges = accountChanges
    self.connect = connect
  }

  public nonisolated var stateUpdates: AsyncStream<SyncState> { coordinator.stateUpdates }

  public nonisolated var acceptedUpdates: AsyncStream<Void> { coordinator.acceptances.stream() }

  public nonisolated var fileTransfers: AsyncStream<[String: FileTransfer]> { transfers.stream }

  public func fetchFile(_ key: String) async throws -> URL {
    guard await started() else {
      try Task.checkCancellation()
      throw FileFetchFailure.notSyncing
    }
    guard await connectNow(), let fileFetcher = parts?.fileFetcher else {
      try Task.checkCancellation()
      throw FileFetchFailure.notSyncing
    }
    return try await fileFetcher.fetch(key)
  }

  private func started() async -> Bool {
    switch phase {
    case .running: return true
    case .stopped, .resolving: return false
    case .idle: break
    }
    let waiter = Promise<Bool>()
    startWaiters.append(waiter)
    defer { startWaiters.removeAll { $0 === waiter } }
    return (try? await waiter.value()) ?? false
  }

  private func answerStartWaiters(_ started: Bool) { startWaiters.forEach { $0.resolve(.success(started)) } }

  var stopped: Bool {
    switch phase {
    case .stopped, .resolving: true
    case .idle, .running: false
    }
  }
  var running: Run? { if case .running(let run) = phase { run } else { nil } }
  var parts: Parts? { if case .connected(let parts) = running?.link { parts } else { nil } }
  var connected: Bool { parts != nil }

  @discardableResult
  func update<T>(_ generation: SyncGeneration, _ change: (inout Run) -> T) -> T? {
    guard case .running(var run) = phase, run.generation === generation else { return nil }
    let result = change(&run)
    phase = .running(run)
    return result
  }

  func makeParts(_ cloud: any SyncCloud, _ generation: SyncGeneration) -> Parts {
    let sender = RecordSender(uploader: cloud, coordinator: coordinator, generation: generation) { [coordinator] in
      try await PeerFloor(zoneID: Self.zoneID).settle(cloud, coordinator: coordinator)
      await coordinator.succeeded()
    }
    return Parts(
      puller: ZonePuller(source: cloud, coordinator: coordinator, generation: generation),
      sender: sender,
      fileSender: FileSender(cloud: cloud, coordinator: coordinator, board: transfers, generation: generation) { await sender.ready() },
      fileFetcher: FileFetcher(cloud: cloud, coordinator: coordinator, board: transfers, generation: generation)
    )
  }

  func spawn(_ generation: SyncGeneration, _ body: @escaping @Sendable () async -> Void) {
    guard !generation.isOver else { return }
    let id = UUID()
    let task = Task {
      await body()
      update(generation) { $0.background[id] = nil }
    }
    update(generation) { $0.background[id] = task }
  }

  public func start() async {
    await stopping?.value
    if case .running = phase { return }
    let generation = SyncGeneration()
    var run = Run(generation: generation, cloud: connect())
    phase = .running(run)
    await coordinator.use(run.gate)
    await coordinator.loadToken()
    guard !generation.isOver else { return }
    let due = coordinator.retryDue.stream(), network = NetworkReturns.stream()
    let accountChanged = accountChanges.notifications(named: .CKAccountChanged)
    run.watchers = [
      Task { [coordinator] in
        for await _ in network {
          await coordinator.connected()
          self.recheckIfWaiting(generation, for: .networkReturned)
        }
      },
      Task { for await _ in due { await self.parts?.puller.due() } },
      Task { [weak self] in
        for await _ in accountChanged { await self?.recheck(generation) }
      },
    ]
    update(generation) { $0.watchers = run.watchers }
    answerStartWaiters(true)
    await connectNow()
  }

  public func stop() async { await stop(becoming: .stopped) }

  private func stop(becoming next: Phase) async {
    let run = running
    run?.generation.end()
    phase = next
    answerStartWaiters(false)
    accountChecks.yield(())
    let previous = stopping
    let teardown = Task {
      await previous?.value
      guard let run else { return }
      let checking = run.checking
      checking?.cancel()
      run.tasks.forEach { $0.cancel() }
      for task in run.tasks { await task.value }
      _ = await checking?.value
      guard case .connected(let parts) = run.link else { return }
      await parts.puller.stop()
      await parts.sender.stop()
      await parts.fileSender.stop()
      await parts.fileFetcher.stop()
    }
    stopping = teardown
    await teardown.value
  }

  @discardableResult
  public func syncNow() async throws -> SyncPullResult {
    guard await started() else {
      try Task.checkCancellation()
      return .incomplete
    }
    guard await connectNow(), let run = running, let parts else {
      try Task.checkCancellation()
      return .incomplete
    }
    let generation = run.generation
    if Self.subscribesToAlerts, await coordinator.alertSubscription != .active, !generation.isOver,
      running?.alertsAttemptedAt.map({ ContinuousClock.now - $0 >= Self.alertRetryInterval }) ?? true
    {
      update(generation) { $0.alertsAttemptedAt = .now }
      spawn(generation) { await self.ensureAlertSubscriptions(run.cloud, generation) }
    }
    await parts.sender.kick()
    return try await parts.puller.pull()
  }

  @discardableResult
  public func send(recordNames: Set<String>) async -> Bool {
    guard let sender = parts?.sender else { return false }
    return await sender.send(recordNames)
  }

  public func push() async {
    await parts?.sender.flush()
  }

  public func resolve(_ resolution: SyncResolution) async throws {
    await stop(becoming: .resolving)
    do {
      try await coordinator.resolve(resolution)
    } catch {
      await restartAfterResolving()
      throw error
    }
    await restartAfterResolving()
  }

  private func restartAfterResolving() async {
    guard case .resolving = phase else { return }
    await start()
  }
}
