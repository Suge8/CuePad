import CloudKit
import Foundation
import os

/// iCloud 同步入口：私有数据库里一个自定义同步区，自己的同步循环——一个拉取器（`ZonePuller`）、一个发送者（`RecordSender`），
/// 逻辑在协调器（`SyncCoordinator`）。
///
/// 用法：`let sync = CloudSync(store: store)`；`await sync.start()` 认账号（认不了由这里自己按退避再认）、开始上传，第一次拉由 App 发起
/// （`syncNow`，它等得到拉完）；界面订阅 `stateUpdates`，状态为 `.needsDecision` 时让用户选择后调用 `resolve(_:)`。冲突副本由 `CueStore.conflicts()` 提供。
/// 实时层订阅 `acceptedUpdates`（服务器收下了本机的一批改动），要立刻拉一次就调 `syncNow`，门铃的密钥经 `relaySecret` 取。
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
  /// 认过账号（可用、是上次同步的那个）：拉取与上传都开始了。认不了（离线、没登录）时不拉也不传：本机的同步元数据可能属于上一个账号。
  private var connected = false
  /// 正在认的那一次：同时要认的都等它。
  private var connecting: Task<Bool, Never>?
  private var accountBackoff = Backoff()
  /// 认不了时下次再认的时刻：之前来的立即同步（按节奏的拉取、门铃都可能很密）不另认，账号变化不等它。
  private var accountRetryAt: ContinuousClock.Instant?
  private var accountRetry: Task<Void, Never>?
  private var accountWatcher: Task<Void, Never>?
  /// `start()` 之前就要拉的（冷启动时先到的推送）：开始了再拉。
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  /// 等账号认好的（`relaySecret`）：每认完一次账号叫醒一遍，各自再看能不能同步。
  private var accountWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
  /// 认完账号的次数：等的一方看条件前记下，条件没满足再等时次数已变就不等（看条件时跨了 actor，期间可能刚认完）。
  private var accountChecks = 0
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

  /// 连上 iCloud 并认一次账号（返回时认完；认不了的这里自己按退避再认）。
  public func start() async {
    guard cloud == nil else { return }
    let cloud = connect()
    self.cloud = cloud
    puller = ZonePuller(source: cloud, coordinator: coordinator)
    sender = RecordSender(uploader: cloud, coordinator: coordinator) { [coordinator] in
      try await PeerFloor(zoneID: Self.zoneID).settle(cloud, coordinator: coordinator)
      await coordinator.succeeded()
    }
    await coordinator.loadToken()
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
    await sender?.stop()
    sender = nil
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
      Self.log.notice("认 iCloud 账号失败，稍后再认：\(error.brief, privacy: .public)")
      guard !connected else { return true }
      if SyncFault(error).isOffline { await coordinator.failed(error) } else { await coordinator.accountStatus(.couldNotDetermine) }
      retryAccount()
      return false
    }
    accountRetry?.cancel()
    accountRetryAt = nil
    accountBackoff.reset()
    guard !connected else {
      accountChecked()
      return true
    }
    guard await coordinator.canSync, let sender else {
      accountChecked()
      return false
    }
    connected = true
    accountChecked()
    await sender.start()
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
      do { try await self.syncNow() } catch { Self.log.notice("拉取失败：\(error.brief, privacy: .public)") }
    }
  }

  /// 账号变了：再认一次（换了账号就停下等你决定）；能同步的在新账号的数据库里建订阅（里面还没有），再拉一次。
  private func accountChanged() async {
    guard let cloud else { return }
    let wasConnected = connected
    accountRetryAt = nil  // 账号变了是新情况，不等上次失败的退避
    guard wasConnected ? await checkAccount(cloud) : await connectNow() else { return }
    if wasConnected { await ensureAlertSubscriptions(cloud) }  // 刚开始的已在建
    do { try await puller?.pull() } catch { Self.log.notice("拉取失败：\(error.brief, privacy: .public)") }
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
    while true {
      let checks = accountChecks
      if connected, await coordinator.canSync { break }
      try await nextAccountCheck(after: checks)
    }
    guard let cloud else { throw CancellationError() }
    return try await cloud.relaySecret()
  }

  /// 认完了一次账号：叫醒等着的（`relaySecret`）。
  private func accountChecked() {
    accountChecks += 1
    for waiter in accountWaiters.values { waiter.resume() }
    accountWaiters = [:]
  }

  /// 等下一次认完账号；`checks` 之后已认过就当场返回。
  private func nextAccountCheck(after checks: Int) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else if accountChecks != checks {
          continuation.resume()
        } else {
          accountWaiters[id] = continuation
        }
      }
    } onCancel: {
      Task { await self.stopWaiting(id) }
    }
  }

  private func stopWaiting(_ id: UUID) { accountWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }

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
