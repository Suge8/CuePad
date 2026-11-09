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
  /// 听 `CKAccountChanged` 的那一个：测试给自己的，免得全进程的通知叫醒并行的别的测试（通知一到闸门就关）。
  private let accountChanges: NotificationCenter
  enum Phase {
    case idle
    case running(Run)
    case resolving
    case stopped
  }
  var phase = Phase.idle
  private let transfers = TransferBoard()
  /// 还没收尾的停止：`start` 等它收尾才建新一代（新旧发送者不并存，`RecordSender`）。
  private var stopping: Task<Void, Never>?
  private var startWaiters: [Promise<Bool>] = []
  /// 每认完一次账号、每次停下给一个：等账号认好的（`relaySecret`）据此再看能不能同步。
  let accountChecks = Broadcast<Void>(bufferingPolicy: .bufferingNewest(1))
  static let alertRetryInterval = Duration.seconds(60)
  static let log = Logger(subsystem: AppIdentity.id, category: "sync")

  /// 只有 iOS 建立：Mac 不注册推送，靠等待理由驱动的拉取。App 需要请求通知权限并注册远程通知。
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

  /// 先给出当前快照，之后状态或问题列表每次变化给出新快照。
  public nonisolated var stateUpdates: AsyncStream<SyncState> { coordinator.stateUpdates }

  /// 每次服务器收下本机的一批改动给出一个，不补之前的。
  public nonisolated var acceptedUpdates: AsyncStream<Void> { coordinator.acceptances.stream() }

  /// 附件文件此刻在路上的（按 key，见 `FileTransfer`）：先给当前快照，之后每次变化给新快照。一个 key 离开快照就是那一趟结束了，
  /// 文件在不在本机看附件目录（取完了就在；传完的本来就在）。
  public nonisolated var fileTransfers: AsyncStream<[String: FileTransfer]> { transfers.stream }

  /// 这个附件文件在本机的位置：没有就现在从 iCloud 取（不看手机自动取的条件），附件记录还没到就等它到（发出的设备还在传），
  /// 服务器要求等就等到点；没开始同步的等开始。这台不同步（没认过账号、停下了）抛 `FileFetchFailure.notSyncing`，文件坏了抛 `.damaged`，网络与 iCloud 的失败原样抛出；被取消就抛出。
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

  /// 开始了（true）；还没开始的等到开始，等的时候被取消、或停下了（含等的时候停下）为 false。
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

  /// 改 `generation` 那一代；那一代已经结束的什么都不改，返回 nil。
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

  /// 本代的后台任务：登记在 `Run` 里，`stop` 取消并等它；那一代已经结束的不起。
  func spawn(_ generation: SyncGeneration, _ body: @escaping @Sendable () async -> Void) {
    guard !generation.isOver else { return }
    let id = UUID()
    let task = Task {
      await body()
      update(generation) { $0.background[id] = nil }
    }
    update(generation) { $0.background[id] = task }
  }

  /// 第一个调用方返回时认完（认不了的这里自己按退避再认）；认的途中再调的当场返回。
  public func start() async {
    await stopping?.value
    if case .running = phase { return }
    let generation = SyncGeneration()
    var run = Run(generation: generation, cloud: connect())
    phase = .running(run)
    await coordinator.use(run.gate)
    await coordinator.loadToken()
    guard !generation.isOver else { return }  // 读令牌期间停下了
    let due = coordinator.retryDue.stream(), network = NetworkReturns.stream()
    run.watchers = [
      Task { [coordinator] in
        for await _ in network {
          await coordinator.connected()
          self.recheckIfWaiting(generation, for: .networkReturned)
        }
      },
      Task { for await _ in due { await self.parts?.puller.due() } },  // 没连上就没拉过，没有欠着的
      Task { [weak self, accountChanges] in
        for await _ in accountChanges.notifications(named: .CKAccountChanged) {
          await self?.recheck(generation)
        }
      },
    ]
    update(generation) { $0.watchers = run.watchers }
    answerStartWaiters(true)
    await connectNow()
  }

  /// 等开始的调用方得到"没在同步"，等账号认好的（`relaySecret`）抛出。
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

  /// 立即同步：拉一次（返回时拉完），顺带让发送者发一轮（不等，守着它的重试时刻）；`start()` 之前来的等开始了再拉，本代还没认过账号的先认。
  /// 通知订阅没建成的话顺带在后台重试。
  /// 返回本次拉取的结果；账号、暂停与退避导致的未拉取不是成功，不能从全局同步状态反推。
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
      update(generation) { $0.alertsAttemptedAt = .now }  // 任务起来之前再来的不另起
      spawn(generation) { await self.ensureAlertSubscriptions(run.cloud, generation) }
    }
    await parts.sender.kick()
    return try await parts.puller.pull()
  }

  /// 马上传这几条（同一次写入写出的一起，一个请求）：不进攒批窗口、不等后台那批；返回时它们都有了结果
  /// （全被服务器收下为 true，离线等没传成的为 false，之后优先重试）。要传什么（保存还是删除）由库推导：本机删掉的就是删除。
  @discardableResult
  public func send(recordNames: Set<String>) async -> Bool {
    guard let sender = parts?.sender else { return false }
    return await sender.send(recordNames)
  }

  /// 把待推送全部发出去，返回时这一轮结束。
  public func push() async {
    await parts?.sender.flush()
  }

  /// 处理 `.needsDecision`：先停下这一代（旧代的拉取、上传不会在清库、重置之后写进来），处理完重新开始同步。处理失败也重新开始（仍停在要你决定）。
  /// 处理期间有人 `stop` 的不再开始。
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
