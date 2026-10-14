import CloudKit
import Foundation
import os

/// iCloud 同步入口：私有数据库里一个自定义同步区，CKSyncEngine 驱动。
///
/// 用法：`let sync = CloudSync(store: store)`；`try await sync.start()`；界面订阅 `stateUpdates`，
/// 状态为 `.needsDecision` 时让用户选择后调用 `resolve(_:)`。冲突副本由 `CueStore.conflicts()` 提供。
/// 需要 App 带 iCloud（CloudKit）entitlement 与容器；没有 entitlement 的进程（命令行测试）不能调用 `start()`。
public actor CloudSync {
  private let containerIdentifier: String
  private let zoneID: CKRecordZone.ID
  private let queue = EngineQueue()
  private let coordinator: SyncCoordinator
  /// CKSyncEngine 只弱引用委托：这里是它唯一的强持有者，与 CloudSync 同生命周期。
  /// 曾经只是 `start()` 里的局部变量，返回后即被释放，引擎的事件全被丢掉（"the delegate may have been deallocated"）。
  nonisolated let engineDelegate: EngineBridge
  private let subscribesToAlerts: Bool
  private var engine: CKSyncEngine?
  private var puller: ZoneChangePuller?
  private var uploader: (any RecordUploader)?
  private var accountWatcher: Task<Void, Never>?

  /// `subscribesToAlerts`：是否在私有数据库建立"Pi 等你确认 / 完成"与 Cue 消息的服务端通知订阅（`AlertSubscriptions`）。默认只有 iOS 建立
  /// （Mac 是记录的写方，不需要）。App 需要请求通知权限并注册远程通知，见 `PiAlertRoute`、`CueAlertRoute`。
  public init(
    store: CueStore, containerIdentifier: String = "iCloud.com.sugeh.cuepad", zoneName: String = "CuePad",
    subscribesToAlerts: Bool = CloudSync.subscribesToAlertsByDefault
  ) {
    self.subscribesToAlerts = subscribesToAlerts
    self.containerIdentifier = containerIdentifier
    zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    coordinator = SyncCoordinator(store: store, queue: queue, zoneID: zoneID)
    engineDelegate = EngineBridge(coordinator: coordinator, zoneID: zoneID)
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
    guard engine == nil else { return }
    let container = CKContainer(identifier: containerIdentifier)
    await coordinator.handle(.accountStatus(try await container.accountStatus()))

    let saved = try await coordinator.savedEngineState()
    let state = saved.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
    let engine = CKSyncEngine(
      CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: state, delegate: engineDelegate))
    self.engine = engine
    puller = ZoneChangePuller(source: DatabaseZoneChanges(database: container.privateCloudDatabase, zoneID: zoneID), coordinator: coordinator)
    uploader = DatabaseRecordUploader(database: container.privateCloudDatabase)
    await queue.attach(engine)

    try await coordinator.start()
    await ensureAlertSubscriptions(container)
    accountWatcher = Task { [coordinator, weak self] in
      for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) {
        guard let account = try? await container.accountStatus() else { continue }
        await coordinator.handle(.accountStatus(account))
        await self?.ensureAlertSubscriptions(container)  // 账号切换后新账号的数据库里还没有订阅
      }
    }
  }

  public func stop() async {
    accountWatcher?.cancel()
    accountWatcher = nil
    await coordinator.stop()
    await queue.attach(nil)
    engine = nil
    puller = nil
    uploader = nil
  }

  /// 直接向服务器拉一次同步区的变化（不经引擎、不推送本机改动）：推送之外的主动拉取，见 `SyncPoller`、`ZoneChangePuller`。
  public func pullChanges() async throws {
    try await puller?.pull()
  }

  /// 还没有主动拉取的令牌就先取（见 `ZoneChangePuller.prepare`）。
  public func preparePull() async throws {
    try await puller?.prepare()
  }

  /// 立即上传这一条记录（不等引擎的自动调度，也不排进引擎的队列，见 `RecordUploader`）：手机写出投送请求后调用，Mac 才能尽早拉到。
  /// `deleted`：本机删掉了它（撤回还没被 Mac 领取的请求），发的是删除。引擎里排着的这一条先去掉，免得再发一遍；整个请求失败（离线）时放回去，由引擎重试。
  public func sendNow(recordName: String, deleted: Bool = false) async throws {
    guard let engine, let uploader else { return }
    let id = CKRecord.ID(recordName: recordName, zoneID: zoneID)
    let change: CKSyncEngine.PendingRecordZoneChange = deleted ? .deleteRecord(id) : .saveRecord(id)
    engine.state.remove(pendingRecordZoneChanges: [change])
    let result: SendNowResult
    do {
      result = try await coordinator.sendNow(id, deleted: deleted, via: uploader)
    } catch {
      engine.state.add(pendingRecordZoneChanges: [change])
      throw error
    }
    switch result {
    case .received: engine.state.remove(pendingRecordZoneChanges: [change])  // 重传时结果入口可能又登记过一次
    case .receivedWithNewerVersionPending: break  // 更新的版本由结果入口登记，引擎来传
    case .rejected:
      engine.state.add(pendingRecordZoneChanges: [change])  // 服务器没收下（限流、服务暂不可用等）：引擎照常重试
      throw SyncError.notUploaded
    }
  }

  /// 立即拉取并推送（不等引擎的自动调度）。通知订阅没建成的话顺便重试，并按数据库重新登记待推送（回到前台时调用）。
  public func syncNow() async throws {
    guard let engine else { return }
    if subscribesToAlerts, await coordinator.alertSubscription != .active {
      await ensureAlertSubscriptions(CKContainer(identifier: containerIdentifier))
    }
    try await engine.fetchChanges()
    try await coordinator.reconcile()  // 待推送以数据库为准：引擎对失败的记录不一定重试，丢了的在这里补登记
    try await engine.sendChanges()
  }

  private func ensureAlertSubscriptions(_ container: CKContainer) async {
    guard subscribesToAlerts else { return }
    let status = await AlertSubscriptions(zoneID: zoneID).ensure(in: DatabaseSubscriptions(database: container.privateCloudDatabase))
    await coordinator.setAlerts(status)
  }

  /// 处理 `.needsDecision`：随后用全新的引擎状态重新开始同步。
  public func resolve(_ resolution: SyncResolution) async throws {
    try await coordinator.resolve(resolution)
    await stop()
    try await start()
  }
}

/// 把同步逻辑的登记落到 CKSyncEngine 的待办状态上。
private actor EngineQueue: ChangeQueue {
  private var engine: CKSyncEngine?

  func attach(_ engine: CKSyncEngine?) { self.engine = engine }

  func enqueue(saves: [CKRecord.ID], deletes: [CKRecord.ID]) {
    engine?.state.add(pendingRecordZoneChanges: saves.map { .saveRecord($0) } + deletes.map { .deleteRecord($0) })
  }

  func ensureZone(_ zoneID: CKRecordZone.ID) {
    engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
  }
}

/// CKSyncEngine 的委托：只做事件翻译，逻辑全在 `SyncCoordinator`。
final class EngineBridge: CKSyncEngineDelegate, Sendable {
  private static let logger = Logger(subsystem: "com.sugeh.cuepad", category: "sync")
  let coordinator: SyncCoordinator
  let zoneID: CKRecordZone.ID

  init(coordinator: SyncCoordinator, zoneID: CKRecordZone.ID) {
    self.coordinator = coordinator
    self.zoneID = zoneID
  }

  func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    switch event {
    case .stateUpdate(let update):
      // 序列化不了就没法存引擎状态，下次启动要把整个同步区重拉一遍：留一条日志，不静默
      do {
        await coordinator.handle(.stateUpdate(try JSONEncoder().encode(update.stateSerialization)))
      } catch {
        Self.logger.error("引擎状态序列化失败，下次启动将重新拉取：\(error)")
      }
    case .accountChange(let change):
      switch change.changeType {
      case .signIn: await coordinator.handle(.accountChange(.signedIn))
      case .signOut: await coordinator.handle(.accountChange(.signedOut))
      case .switchAccounts: await coordinator.handle(.accountChange(.switched))
      @unknown default: break
      }
    case .fetchedDatabaseChanges(let changes):
      for deletion in changes.deletions where deletion.zoneID == zoneID {
        switch deletion.reason {
        case .deleted: await coordinator.handle(.cloudDataLost(.deleted))
        case .purged: await coordinator.handle(.cloudDataLost(.purged))
        case .encryptedDataReset: await coordinator.handle(.cloudDataLost(.encryptedDataReset))
        @unknown default: await coordinator.handle(.cloudDataLost(.purged))
        }
      }
    case .fetchedRecordZoneChanges(let changes):
      await coordinator.handle(.fetched(
        modifications: changes.modifications.map(\.record),
        deletions: changes.deletions.map { ($0.recordID, $0.recordType) }))
    case .sentRecordZoneChanges(let sent):
      await coordinator.handle(.sent(
        saved: sent.savedRecords,
        failedSaves: sent.failedRecordSaves.map { ($0.record, $0.error) },
        deleted: sent.deletedRecordIDs,
        failedDeletes: sent.failedRecordDeletes.map { ($0.key, $0.value) }))
    case .sentDatabaseChanges(let sent):
      for failure in sent.failedZoneSaves { await coordinator.handle(.zoneSaveFailed(failure.error)) }
    case .willFetchChanges, .willSendChanges: await coordinator.handle(.syncing(true))
    case .didFetchChanges, .didSendChanges: await coordinator.handle(.syncing(false))
    default: break
    }
  }

  func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
    let changes = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
    return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { await self.coordinator.record(for: $0) }
  }
}
