import CloudKit
import Foundation
import os

/// iCloud 同步入口：私有数据库里一个自定义同步区，自己的同步循环——一个拉取器（`ZonePuller`）、一个发送者（`RecordSender`），
/// 附件的文件另走一路（传 `FileSender`、取 `FileFetcher`），逻辑在协调器（`SyncCoordinator`）。
///
/// 用法：`let sync = CloudSync(store: store)`；`await sync.start()` 认账号（认不了由这里自己按退避再认）、开始上传，第一次拉由 App 发起
/// （`syncNow`，它等得到拉完）；界面订阅 `stateUpdates`，状态为 `.needsDecision` 时让用户选择后调用 `resolve(_:)`。冲突副本由 `CueStore.conflicts()` 提供。
/// 实时层订阅 `acceptedUpdates`（服务器收下了本机的一批改动），要立刻拉一次就调 `syncNow`，门铃的密钥经 `relaySecret` 取。
/// 附件文件的进度订阅 `fileTransfers`，用到本机还没有的文件调 `fetchFile`。
/// 需要 App 带 iCloud（CloudKit）entitlement 与容器；没有 entitlement 的进程（命令行测试）不能调用 `start()`。
///
/// 一次 `start()` 到 `stop()` 是一代（`SyncGeneration`）：本代的拉取器、发送者、文件两路与这里起的认账号、重试、订阅、文件启动等任务都属于它。
/// `stop` 一开始就结束这一代，再取消并等它们收尾；任务在每个 await 之后先看这一代结束没有再改状态，旧代不会在停止或重启之后写新一代的状态。
/// `start` 等上一次 `stop` 收尾完才建新一代：新旧两代的发送者不并存。`resolve` 先停、再处理、再开始：处理（清库、重置元数据）时旧代已不再写。
///
/// 冷启动：认过账号就能拉，第一拉不等别的；最低对端版本（`PeerFloor`）由发送者在第一次上传前对（上传等它，拉取不等：拉到的页里有门槛就当场看，
/// `SyncCoordinator.meet`）；通知订阅在后台另建，彼此独立。状态在第一次请求成功前一直是正在连接。
///
/// 不用 CKSyncEngine：它的手动拉取只在收到过推送、知道哪个区有变化时才真的发请求（macOS 27.2 实测：全新状态的第一次之后，
/// 没收到推送就原地返回，有没有推送权限、限定区、带旧状态重启都一样），而 Mac 不收推送；它的待办队列又是库里推导的待推送之外的第二份事实。
/// 拉：令牌只有库里一份，什么时候拉由 App 定（有等待理由时按节奏、回到前台、立即同步、手机收到推送）。
/// 推：库里推导的待推送是唯一队列，同一条记录同一时刻只在一批里。
public actor CloudSync {
  private static let containerIdentifier = AppIdentity.iCloudContainer
  static let zoneID = CKRecordZone.ID(zoneName: "CuePad", ownerName: CKCurrentUserDefaultName)
  let coordinator: SyncCoordinator
  /// 连上 iCloud（`SyncCloud`）：`start()` 里才连，没有 entitlement 的进程一建容器就崩。
  private let connect: @Sendable () -> any SyncCloud
  enum Phase {
    case idle
    case running(Run)
    case stopped
  }
  /// 一代与它连上的 iCloud。
  struct Run {
    let generation: SyncGeneration
    let cloud: any SyncCloud
    var link = Link.unconfirmed
  }
  /// 认账号的进度。认过账号（可用、是上次同步的那个）才连上，拉取器、发送者与文件两路这时才建：认不了（离线、没登录）时不拉也不传，
  /// 本机的同步元数据可能属于上一个账号。连上之后认不清了（账号变了、取不到账号名）由协调器挡住拉传（`SyncCoordinator.accountUnconfirmed`），
  /// 这里仍是连上：部件不重建。
  enum Link {
    case unconfirmed
    /// 同时要认的都等这一次。
    case connecting(Task<Bool, Never>)
    case connected(Parts)
  }
  struct Parts {
    let puller: ZonePuller
    let sender: RecordSender
    let fileSender: FileSender
    let fileFetcher: FileFetcher
  }
  var phase = Phase.idle
  private let transfers = TransferBoard()
  var accountBackoff = Backoff()
  /// 认不了时下次再认的时刻：之前来的立即同步（按节奏的拉取、门铃都可能很密）不另认，账号变化不等它。
  var accountRetryAt: ContinuousClock.Instant?
  var accountRetry: Task<Void, Never>?
  private var accountWatcher: Task<Void, Never>?
  /// 重试的等待结束时补拉、网络路径恢复时提前结束连不上的等待（`SyncCoordinator+Hold`）。
  private var retryWatchers: [Task<Void, Never>] = []
  /// 还没收尾的停止：`start` 等它收尾才建新一代（新旧发送者不并存，`RecordSender`）。
  private var stopping: Task<Void, Never>?
  /// 本代起的其余后台任务（文件那一路的启动、建通知订阅）：`stop` 统一取消、等收尾。
  private var background: [UUID: Task<Void, Never>] = [:]
  /// `start()` 之前就要拉的（冷启动时先到的推送）：开始了再拉（true）；等的时候被取消、或停下了（false）。
  private var startWaiters: [Promise<Bool>] = []
  /// 每认完一次账号给一个：等账号认好的（`relaySecret`）据此再看能不能同步。
  let accountChecks = Broadcast<Void>(bufferingPolicy: .bufferingNewest(1))
  /// 上一次建通知订阅的时刻：没建成时 `syncNow` 顺带重试，至多每 `alertRetryInterval` 一次（按节奏的拉取、门铃也走它，可能很密）。
  var alertsAttemptedAt: ContinuousClock.Instant?
  private static let alertRetryInterval = Duration.seconds(60)
  static let log = Logger(subsystem: AppIdentity.id, category: "sync")

  /// 是否在私有数据库建立服务端订阅（`AlertSubscriptions`：要紧的变化把 App 叫到后台拉一次，"Pi 等你确认 / 完成"与 Cue 消息的可见通知）。
  /// 只有 iOS 建立：Mac 不注册推送，靠等待理由驱动的拉取。App 需要请求通知权限并注册远程通知。
  #if os(iOS)
  static let subscribesToAlerts = true
  #else
  static let subscribesToAlerts = false
  #endif

  public init(store: CueStore) {
    self.init(store: store) { CloudDatabase(container: CKContainer(identifier: Self.containerIdentifier), zoneID: Self.zoneID) }
  }

  init(store: CueStore, connect: @escaping @Sendable () -> any SyncCloud) {
    coordinator = SyncCoordinator(store: store, zoneID: Self.zoneID)
    self.connect = connect
  }

  /// 先给出当前快照，之后状态或问题列表每次变化给出新快照。
  public nonisolated var stateUpdates: AsyncStream<SyncState> { coordinator.stateUpdates }

  /// 之后每次服务器收下本机的一批改动给出一个（不补之前的；实时层据此按门铃）。
  public nonisolated var acceptedUpdates: AsyncStream<Void> { coordinator.acceptances.stream() }

  /// 附件文件此刻在路上的（按 key，见 `FileTransfer`）：先给当前快照，之后每次变化给新快照。一个 key 离开快照就是那一趟结束了，
  /// 文件在不在本机看附件目录（取完了就在；传完的本来就在）。
  public nonisolated var fileTransfers: AsyncStream<[String: FileTransfer]> { transfers.stream }

  /// 这个附件文件在本机的位置：没有就现在从 iCloud 取（不看手机自动取的条件），附件记录还没到就等它到（发出的设备还在传），
  /// 服务器要求等就等到点；没开始同步的等开始。这台不同步（没认过账号、停下了）抛 `FileFetchFailure.notSyncing`，文件坏了抛 `.damaged`，网络与 iCloud 的失败原样抛出；被取消就抛出。
  /// Mac 把带附件的话交给会话前用它确保文件在本机。
  public func fetchFile(_ key: String) async throws -> URL {
    guard await started() else {
      try Task.checkCancellation()
      throw FileFetchFailure.notSyncing
    }
    guard await connectNow(), let fileFetcher = parts?.fileFetcher else { throw FileFetchFailure.notSyncing }
    return try await fileFetcher.fetch(key)
  }

  /// 开始了（true）；还没开始的等到开始，等的时候被取消、或停下了（含等的时候停下）为 false。
  private func started() async -> Bool {
    switch phase {
    case .running: return true
    case .stopped: return false
    case .idle: break
    }
    let waiter = Promise<Bool>()
    startWaiters.append(waiter)
    defer { startWaiters.removeAll { $0 === waiter } }
    return (try? await waiter.value()) ?? false
  }

  private func answerStartWaiters(_ started: Bool) { startWaiters.forEach { $0.resolve(.success(started)) } }

  var stopped: Bool { if case .stopped = phase { true } else { false } }
  var running: Run? { if case .running(let run) = phase { run } else { nil } }
  var parts: Parts? { if case .connected(let parts) = running?.link { parts } else { nil } }
  var connected: Bool { parts != nil }

  /// 换掉 `generation` 那一代的连接；那一代已经结束的不动。
  func setLink(_ link: Link, of generation: SyncGeneration) {
    guard case .running(var run) = phase, run.generation === generation else { return }
    run.link = link
    phase = .running(run)
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

  /// 本代的后台任务：结束时自己从登记里去掉。
  func spawn(_ body: @escaping @Sendable () async -> Void) {
    let id = UUID()
    background[id] = Task {
      await body()
      background[id] = nil
    }
  }

  /// 连上 iCloud 并认一次账号（返回时认完；认不了的这里自己按退避再认）。
  public func start() async {
    await stopping?.value
    if case .running = phase { return }
    let generation = SyncGeneration()
    phase = .running(Run(generation: generation, cloud: connect()))
    await coordinator.loadToken()
    guard !generation.isOver else { return }  // 读令牌期间停下了
    let due = coordinator.retryDue.stream(), network = NetworkReturns.stream()
    retryWatchers = [
      Task { [coordinator] in for await _ in network { await coordinator.connected() } },
      Task { for await _ in due { await self.parts?.puller.due() } },  // 没连上就没拉过，没有欠着的
    ]
    accountWatcher = Task { [weak self] in
      for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) {
        await self?.accountChanged()
      }
    }
    answerStartWaiters(true)
    await connectNow()
  }

  /// 停下这一代：当场结束它，取消并等本代的认账号、重试、订阅、文件启动收尾，再停拉取器、发送者与文件两路；等开始的调用方得到"没在同步"，
  /// 等账号认好的（`relaySecret`）抛出。
  public func stop() async {
    let link = running?.link
    running?.generation.end()
    phase = .stopped
    answerStartWaiters(false)
    accountChecks.yield(())
    let tasks = Array(background.values) + retryWatchers + [accountWatcher, accountRetry].compactMap { $0 }
    // 本代的连接当场摘下：收尾期间别的调用 start 起的新一代用的是新的，这里只停摘下的这些
    let (authenticating, parts): (Task<Bool, Never>?, Parts?) =
      switch link {
      case .connecting(let task): (task, nil)
      case .connected(let parts): (nil, parts)
      case .unconfirmed, nil: (nil, nil)
      }
    background = [:]
    retryWatchers = []
    accountWatcher = nil
    accountRetry = nil
    accountRetryAt = nil
    accountBackoff.reset()
    alertsAttemptedAt = nil
    let previous = stopping
    let teardown = Task {
      await previous?.value
      authenticating?.cancel()
      tasks.forEach { $0.cancel() }
      for task in tasks { await task.value }
      _ = await authenticating?.value
      await parts?.puller.stop()
      await parts?.sender.stop()
      await parts?.fileSender.stop()
      await parts?.fileFetcher.stop()
    }
    stopping = teardown
    await teardown.value
  }

  /// 认过就是 true；没认过的认一次（同时要认的等同一次）。
  @discardableResult
  func connectNow() async -> Bool {
    guard let running else { return false }
    switch running.link {
    case .connected: return true
    case .connecting(let task): return await task.value
    case .unconfirmed: break
    }
    if let accountRetryAt, ContinuousClock.now < accountRetryAt { return false }
    let generation = running.generation
    let task = Task { await self.checkAccount(running.cloud, generation) }
    setLink(.connecting(task), of: generation)
    let result = await task.value
    if case .connecting = self.running?.link { setLink(.unconfirmed, of: generation) }
    return result
  }

  /// 立即同步：拉一次（返回时拉完），顺带让发送者发一轮（不等，守着它的重试时刻）。下拉刷新、立即同步按钮、回到前台、按节奏的拉取（`SyncPoller`）、
  /// 手机收到推送、实时层的门铃都只调它；`start()` 之前来的等开始了再拉，没认过账号的先认。通知订阅没建成的话顺带在后台重试（见 `alertsAttemptedAt`）。
  /// 返回本次拉取的结果；账号、暂停与退避导致的未拉取不是成功，不能从全局同步状态反推。
  @discardableResult
  public func syncNow() async throws -> SyncPullResult {
    guard await started() else {
      try Task.checkCancellation()
      return .incomplete
    }
    guard await connectNow(), let running, let parts else { return .incomplete }
    let generation = running.generation
    if Self.subscribesToAlerts, await coordinator.alertSubscription != .active, !generation.isOver,
      alertsAttemptedAt.map({ ContinuousClock.now - $0 >= Self.alertRetryInterval }) ?? true
    {
      alertsAttemptedAt = .now  // 任务起来之前再来的不另起
      spawn { await self.ensureAlertSubscriptions(running.cloud, generation) }
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

  /// 把待推送全部发出去，返回时这一轮结束（iOS 进入后台前）。
  public func push() async {
    await parts?.sender.flush()
  }

  /// 处理 `.needsDecision`：先停下这一代（旧代的拉取、上传不会在清库、重置之后写进来），处理完重新开始同步。处理失败也重新开始（仍停在要你决定）。
  public func resolve(_ resolution: SyncResolution) async throws {
    await stop()
    do {
      try await coordinator.resolve(resolution)
    } catch {
      await start()
      throw error
    }
    await start()
  }
}
