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
  private let coordinator: SyncCoordinator
  /// 连上 iCloud（`SyncCloud`）：`start()` 里才连，没有 entitlement 的进程一建容器就崩。
  private let connect: @Sendable () -> any SyncCloud
  private var cloud: (any SyncCloud)?
  private var puller: ZonePuller?
  private var sender: RecordSender?
  private var fileSender: FileSender?
  private var fileFetcher: FileFetcher?
  private let transfers = TransferBoard()
  /// 认过账号（可用、是上次同步的那个）：拉取与上传都开始了。认不了（离线、没登录）时不拉也不传：本机的同步元数据可能属于上一个账号。
  private var connected = false
  /// 正在认的那一次：同时要认的都等它。
  private var connecting: Task<Bool, Never>?
  private var accountBackoff = Backoff()
  /// 认不了时下次再认的时刻：之前来的立即同步（按节奏的拉取、门铃都可能很密）不另认，账号变化不等它。
  private var accountRetryAt: ContinuousClock.Instant?
  private var accountRetry: Task<Void, Never>?
  private var accountWatcher: Task<Void, Never>?
  /// 重试的等待结束时补拉、网络路径恢复时提前结束连不上的等待（`SyncCoordinator+Hold`）。
  private var retryWatchers: [Task<Void, Never>] = []
  /// `start()` 之前就要拉的（冷启动时先到的推送）：开始了再拉。
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  /// 每认完一次账号给一个：等账号认好的（`relaySecret`）据此再看能不能同步。
  private let accountChecks = Broadcast<Void>(bufferingPolicy: .bufferingNewest(1))
  /// 上一次建通知订阅的时刻：没建成时 `syncNow` 顺带重试，至多每 `alertRetryInterval` 一次（按节奏的拉取、门铃也走它，可能很密）。
  private var alertsAttemptedAt: ContinuousClock.Instant?
  private static let alertRetryInterval = Duration.seconds(60)
  private static let log = Logger(subsystem: AppIdentity.id, category: "sync")

  /// 是否在私有数据库建立服务端订阅（`AlertSubscriptions`：要紧的变化把 App 叫到后台拉一次，"Pi 等你确认 / 完成"与 Cue 消息的可见通知）。
  /// 只有 iOS 建立：Mac 不注册推送，靠等待理由驱动的拉取。App 需要请求通知权限并注册远程通知。
  #if os(iOS)
  private static let subscribesToAlerts = true
  #else
  private static let subscribesToAlerts = false
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
    if cloud == nil { await withCheckedContinuation { startWaiters.append($0) } }
    guard await connectNow(), let fileFetcher else { throw FileFetchFailure.notSyncing }
    return try await fileFetcher.fetch(key)
  }

  /// 连上 iCloud 并认一次账号（返回时认完；认不了的这里自己按退避再认）。
  public func start() async {
    guard cloud == nil else { return }
    let cloud = connect()
    self.cloud = cloud
    let puller = ZonePuller(source: cloud, coordinator: coordinator)
    self.puller = puller
    let sender = RecordSender(uploader: cloud, coordinator: coordinator) { [coordinator] in
      try await PeerFloor(zoneID: Self.zoneID).settle(cloud, coordinator: coordinator)
      await coordinator.succeeded()
    }
    self.sender = sender
    fileSender = FileSender(cloud: cloud, coordinator: coordinator, board: transfers) { await sender.ready() }
    fileFetcher = FileFetcher(cloud: cloud, coordinator: coordinator, board: transfers)
    await coordinator.loadToken()
    let due = coordinator.retryDue.stream(), network = NetworkReturns.stream()
    retryWatchers = [
      Task { [coordinator] in for await _ in network { await coordinator.connected() } },
      Task { for await _ in due { await puller.due() } },
    ]
    accountWatcher = Task { [weak self] in
      for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) {
        await self?.accountChanged()
      }
    }
    for waiter in startWaiters { waiter.resume() }
    startWaiters = []
    await connectNow()
  }

  public func stop() async {
    accountWatcher?.cancel()
    accountWatcher = nil
    accountRetry?.cancel()
    accountRetry = nil
    retryWatchers.forEach { $0.cancel() }
    retryWatchers = []
    await sender?.stop()
    sender = nil
    await fileSender?.stop()
    fileSender = nil
    await fileFetcher?.stop()
    fileFetcher = nil
    puller = nil
    cloud = nil
    connected = false
  }

  /// 认过就是 true；没认过的认一次（同时要认的等同一次）。
  @discardableResult
  private func connectNow() async -> Bool {
    if connected { return true }
    if let connecting { return await connecting.value }
    if let accountRetryAt, ContinuousClock.now < accountRetryAt { return false }
    guard let cloud else { return false }
    let task = Task { await self.checkAccount(cloud) }
    connecting = task
    let result = await task.value
    connecting = nil
    return result
  }

  /// 认账号：状态交给协调器，可用时再认是不是上次同步的那个账号（换了就停下来等你决定）。还没开始的，认过且能同步就开始上传、在后台建订阅；
  /// 已开始后的账号变化（退出、受限、换了账号）由协调器停下（`canSync`）。认不了、暂不可用的按退避再认（`accountBackoff`）；没登录的等账号变化。
  /// 返回此刻是否已开始。拉取由调用方接着发起（`syncNow`、账号变化）。
  @discardableResult
  private func checkAccount(_ cloud: any SyncCloud) async -> Bool {
    do {
      let status = try await withDeadline(RequestLimits.request) { try await cloud.accountStatus() }
      await coordinator.accountStatus(status)
      guard status == .available else {
        if [.temporarilyUnavailable, .couldNotDetermine].contains(status) { retryAccount() }
        return connected
      }
      await coordinator.account(try await withDeadline(RequestLimits.request) { try await cloud.accountName() })
    } catch {
      guard !connected else { return true }
      // 连不上的经协调器按段记（`SyncCoordinator.noteWaiting`）；其余的在这里只记开始认不了的那一次
      if SyncFault(error).isOffline {
        await coordinator.failed(error)
      } else {
        if accountRetryAt == nil { Self.log.notice("认 iCloud 账号失败，按退避再认：\(error.brief, privacy: .public)") }
        await coordinator.accountStatus(.couldNotDetermine)
      }
      retryAccount()
      return false
    }
    accountRetry?.cancel()
    if accountRetryAt != nil { Self.log.notice("认好 iCloud 账号") }
    accountRetryAt = nil
    accountBackoff.reset()
    defer { accountChecks.yield(()) }
    guard !connected else { return true }
    guard await coordinator.canSync, let sender, let fileSender, let fileFetcher else { return false }
    connected = true
    await sender.start()
    await fileFetcher.start()
    Task { await fileSender.start() }  // 先接上一个进程交给系统的上传，第一拉不等它
    alertsAttemptedAt = .now  // 立即同步不另起一遍
    Task { await ensureAlertSubscriptions(cloud) }  // 第一拉不等订阅
    return true
  }

  private func retryAccount() {
    let at = ContinuousClock.now + accountBackoff.next()
    accountRetryAt = at
    accountRetry?.cancel()
    accountRetry = Task {
      try? await Task.sleep(until: at, clock: .continuous)
      guard !Task.isCancelled else { return }
      try? await self.syncNow()  // 拉取失败由协调器归类、按段记（`SyncCoordinator.noteWaiting`）
    }
  }

  /// 账号变了：再认一次（换了账号就停下等你决定）；能同步的在新账号的数据库里建订阅（里面还没有），再拉一次。
  private func accountChanged() async {
    guard let cloud else { return }
    let wasConnected = connected
    accountRetryAt = nil  // 账号变了是新情况，不等上次失败的退避
    guard wasConnected ? await checkAccount(cloud) : await connectNow() else { return }
    if wasConnected { await ensureAlertSubscriptions(cloud) }  // 刚开始的已在建
    try? await puller?.pull()
  }

  /// 立即同步：拉一次（返回时拉完），顺带让发送者发一轮（不等，守着它的重试时刻）。下拉刷新、立即同步按钮、回到前台、按节奏的拉取（`SyncPoller`）、
  /// 手机收到推送、实时层的门铃都只调它；`start()` 之前来的等开始了再拉，没认过账号的先认。通知订阅没建成的话顺带在后台重试（见 `alertsAttemptedAt`）。
  public func syncNow() async throws {
    if cloud == nil { await withCheckedContinuation { startWaiters.append($0) } }
    guard await connectNow(), let cloud, let puller, let sender else { return }
    if Self.subscribesToAlerts, await coordinator.alertSubscription != .active,
      alertsAttemptedAt.map({ ContinuousClock.now - $0 >= Self.alertRetryInterval }) ?? true
    {
      Task { await ensureAlertSubscriptions(cloud) }
    }
    await sender.kick()
    try await puller.pull()
  }

  /// 马上传这几条（同一次写入写出的一起，一个请求）：不进攒批窗口、不等后台那批；返回时它们都有了结果
  /// （全被服务器收下为 true，离线等没传成的为 false，之后优先重试）。要传什么（保存还是删除）由库推导：本机删掉的就是删除。
  @discardableResult
  public func send(recordNames: Set<String>) async -> Bool {
    guard connected, let sender else { return false }
    return await sender.send(recordNames)
  }

  /// 把待推送全部发出去，返回时这一轮结束（iOS 进入后台前）。
  public func push() async {
    guard connected else { return }
    await sender?.flush()
  }

  /// 门铃的密钥（`RelaySecret`）：认过账号、能同步时才去 iCloud 取；没登录、要你决定时一直等到账号认好，不发请求。被取消就抛出。
  public func relaySecret() async throws -> Data {
    let checks = accountChecks.stream()  // 先订阅：看条件时跨了 actor，其间认完的那一次不漏
    if await !accountUsable() {
      for await _ in checks {
        if await accountUsable() { break }
      }
    }
    try Task.checkCancellation()
    guard let cloud else { throw CancellationError() }
    guard await coordinator.admits(.pull) else { throw RetryHeld() }  // 被限流时不另发请求：门铃按自己的退避再来
    return try await cloud.relaySecret()
  }

  private func accountUsable() async -> Bool { connected ? await coordinator.canSync : false }

  private func ensureAlertSubscriptions(_ cloud: any SyncCloud) async {
    guard Self.subscribesToAlerts else { return }
    alertsAttemptedAt = .now
    let status = await AlertSubscriptions(zoneID: Self.zoneID).ensure(in: cloud)
    await coordinator.setAlerts(status)
  }

  /// 处理 `.needsDecision`：随后重新开始同步。
  public func resolve(_ resolution: SyncResolution) async throws {
    try await coordinator.resolve(resolution)
    await stop()
    await start()
  }
}
