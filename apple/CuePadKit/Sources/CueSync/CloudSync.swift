import CloudKit
import Foundation
import os

/// iCloud 同步入口：私有数据库里一个自定义同步区，自己的同步循环——一个拉取器（`ZonePuller`）、一个发送者（`RecordSender`），
/// 逻辑在协调器（`SyncCoordinator`）。
///
/// 用法：`let sync = CloudSync(store: store)`；`try await sync.start()` 认账号、开始上传，第一次拉由 App 发起（`syncNow`，它等得到拉完）；界面订阅 `stateUpdates`，
/// 状态为 `.needsDecision` 时让用户选择后调用 `resolve(_:)`。冲突副本由 `CueStore.conflicts()` 提供。
/// 需要 App 带 iCloud（CloudKit）entitlement 与容器；没有 entitlement 的进程（命令行测试）不能调用 `start()`。
///
/// 不用 CKSyncEngine：它的手动拉取只在收到过推送、知道哪个区有变化时才真的发请求（macOS 27.2 实测：全新状态的第一次之后，
/// 没收到推送就原地返回，有没有推送权限、限定区、带旧状态重启都一样），而 Mac 不收推送；它的待办队列又是库里推导的待推送之外的第二份事实。
/// 拉：令牌只有库里一份，什么时候拉由 App 定（有等待理由时按节奏、回到前台、立即同步、手机收到推送）。
/// 推：库里推导的待推送是唯一队列，同一时刻只有一批在路上。
public actor CloudSync {
  private let containerIdentifier: String
  private let zoneID: CKRecordZone.ID
  private let coordinator: SyncCoordinator
  private let subscribesToAlerts: Bool
  private var container: CKContainer?
  private var puller: ZonePuller?
  private var sender: RecordSender?
  /// 认过账号、拉取与上传都开始了。认不了（离线、没登录）时不拉也不传：本机的同步元数据可能属于上一个账号。
  private var ready = false
  private var accountWatcher: Task<Void, Never>?
  /// 上一次建通知订阅的时刻：没建成时 `syncNow` 顺带重试，至多每 `alertRetryInterval` 一次（它也是按节奏的拉取，每两三秒一次）。
  private var alertsAttemptedAt: ContinuousClock.Instant?
  private static let alertRetryInterval = Duration.seconds(60)
  private static let log = Logger(subsystem: "com.sugeh.cuepad", category: "sync")

  /// `subscribesToAlerts`：是否在私有数据库建立服务端订阅（`AlertSubscriptions`：同步区有变化的静默推送，"Pi 等你确认 / 完成"与
  /// Cue 消息的可见通知）。默认只有 iOS 建立：Mac 不注册推送，靠等待理由驱动的拉取。App 需要请求通知权限并注册远程通知。
  public init(
    store: CueStore, containerIdentifier: String = "iCloud.com.sugeh.cuepad", zoneName: String = "CuePad",
    subscribesToAlerts: Bool = CloudSync.subscribesToAlertsByDefault
  ) {
    self.subscribesToAlerts = subscribesToAlerts
    self.containerIdentifier = containerIdentifier
    zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    coordinator = SyncCoordinator(store: store, zoneID: zoneID)
  }

  public static var subscribesToAlertsByDefault: Bool {
    #if os(iOS)
    true
    #else
    false
    #endif
  }

  public var status: SyncStatus { get async { await coordinator.status } }
  /// 先给出当前快照，之后状态或问题列表每次变化给出新快照。
  public nonisolated var stateUpdates: AsyncStream<SyncState> { coordinator.stateUpdates }

  public func start() async throws {
    guard sender == nil else { return }
    let container = CKContainer(identifier: containerIdentifier)
    self.container = container
    let database = CloudDatabase(database: container.privateCloudDatabase, zoneID: zoneID)
    puller = ZonePuller(source: database, coordinator: coordinator)
    sender = RecordSender(uploader: database, coordinator: coordinator)
    accountWatcher = Task { [weak self] in
      for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) {
        guard let self else { return }
        guard await self.checkAccount(container) else { continue }
        await self.ensureAlertSubscriptions(container)  // 账号切换后新账号的数据库里还没有订阅
        await self.pull()
      }
    }
    if await checkAccount(container) { await ensureAlertSubscriptions(container) }
  }

  public func stop() async {
    accountWatcher?.cancel()
    accountWatcher = nil
    await sender?.stop()
    sender = nil
    puller = nil
    container = nil
    ready = false
  }

  /// 认账号：状态交给协调器，可用时再认是不是上次同步的那个账号（换了就停下来等你决定）。认过且能同步就开始上传；
  /// 返回此刻是否已开始。认不了（离线）的，下一次立即同步或账号变化时再认。拉取由调用方接着发起（`syncNow`、账号变化）。
  @discardableResult
  private func checkAccount(_ container: CKContainer) async -> Bool {
    if !ready {
      do {
        let status = try await container.accountStatus()
        await coordinator.handle(.accountStatus(status))
        guard status == .available else { return false }
        await coordinator.handle(.account(try await container.userRecordID().recordName))
      } catch {
        await coordinator.handle(.accountStatus(.couldNotDetermine))
        Self.log.notice("认 iCloud 账号失败，稍后再认：\(error.brief, privacy: .public)")
        return false
      }
      guard await coordinator.canSync, let sender else { return false }
      ready = true
      await sender.start()
    } else {
      // 已开始后的账号变化：退出、受限、换了账号都由协调器停下（`canSync`）
      do {
        let status = try await container.accountStatus()
        await coordinator.handle(.accountStatus(status))
        if status == .available { await coordinator.handle(.account(try await container.userRecordID().recordName)) }
      } catch {
        Self.log.notice("认 iCloud 账号失败：\(error.brief, privacy: .public)")
      }
    }
    return true
  }

  /// 立即同步：拉一次（返回时拉完），顺带把待推送发出去（不等）。下拉刷新、立即同步按钮、回到前台、按节奏的拉取（`SyncPoller`）、
  /// 手机收到推送都只调它。通知订阅没建成的话顺带在后台重试（见 `alertsAttemptedAt`）。
  public func syncNow() async throws {
    guard let container else { return }
    if !ready { await checkAccount(container) }
    guard ready, let puller, let sender else { return }
    if subscribesToAlerts, await coordinator.alertSubscription != .active,
      alertsAttemptedAt.map({ ContinuousClock.now - $0 >= Self.alertRetryInterval }) ?? true
    {
      Task { await ensureAlertSubscriptions(container) }
    }
    Task { await sender.flush() }
    try await puller.pull()
  }

  private func pull() async {
    do { try await puller?.pull() } catch { Self.log.notice("拉取失败：\(error.brief, privacy: .public)") }
  }

  /// 马上传这一条，排在最前；返回时它所在的那一批有了结果（服务器收下为 true，离线等没传成的为 false，之后照常重试）。
  /// 要传什么（保存还是删除）由库推导：本机删掉的就是删除。
  @discardableResult
  public func send(recordName: String) async -> Bool {
    guard ready, let sender else { return false }
    return await sender.send([recordName])
  }

  /// 把待推送全部发出去，返回时这一轮结束（iOS 进入后台前）。
  public func push() async {
    guard ready else { return }
    await sender?.flush()
  }

  private func ensureAlertSubscriptions(_ container: CKContainer) async {
    guard subscribesToAlerts else { return }
    alertsAttemptedAt = .now
    let status = await AlertSubscriptions(zoneID: zoneID).ensure(in: DatabaseSubscriptions(database: container.privateCloudDatabase))
    await coordinator.setAlerts(status)
  }

  /// 处理 `.needsDecision`：随后重新开始同步。
  public func resolve(_ resolution: SyncResolution) async throws {
    try await coordinator.resolve(resolution)
    await stop()
    try await start()
  }
}
