import CloudKit
import Foundation

/// iCloud 同步入口：私有数据库里一个自定义同步区，CKSyncEngine 驱动。
///
/// 用法：`let sync = CloudSync(store: store)`；`try await sync.start()`；界面订阅 `stateUpdates`，
/// 状态为 `.needsDecision` 时让用户选择后调用 `resolve(_:)`。冲突副本由 `CueStore.conflicts()` 提供。
/// 需要 App 带 iCloud（CloudKit）entitlement 与容器；没有 entitlement 的进程（命令行测试）不能调用 `start()`。
public actor CloudSync {
  private let store: CueStore
  private let containerIdentifier: String
  private let zoneID: CKRecordZone.ID
  private let queue = EngineQueue()
  private let coordinator: SyncCoordinator
  /// CKSyncEngine 只弱引用委托：这里是它唯一的强持有者，与 CloudSync 同生命周期。
  /// 曾经只是 `start()` 里的局部变量，返回后即被释放，引擎的事件全被丢掉（"the delegate may have been deallocated"）。
  nonisolated let engineDelegate: EngineBridge
  private let subscribesToPiAlerts: Bool
  private var engine: CKSyncEngine?
  private var accountWatcher: Task<Void, Never>?

  /// `subscribesToPiAlerts`：是否在私有数据库建立"Pi 等你确认 / 完成"的服务端通知订阅。默认只有 iOS 建立
  /// （Mac 是记录的写方，不需要）。App 需要请求通知权限并注册远程通知，见 `PiAlertRoute`。
  public init(
    store: CueStore, containerIdentifier: String = "iCloud.com.sugeh.cuepad", zoneName: String = "CuePad",
    subscribesToPiAlerts: Bool = CloudSync.subscribesToPiAlertsByDefault
  ) {
    self.subscribesToPiAlerts = subscribesToPiAlerts
    self.store = store
    self.containerIdentifier = containerIdentifier
    zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    coordinator = SyncCoordinator(store: store, queue: queue, zoneID: zoneID)
    engineDelegate = EngineBridge(coordinator: coordinator, zoneID: zoneID)
  }

  public static var subscribesToPiAlertsByDefault: Bool {
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
    await queue.attach(engine)

    try await coordinator.start()
    await ensurePiAlertSubscriptions(container)
    accountWatcher = Task { [coordinator, weak self] in
      for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) {
        guard let account = try? await container.accountStatus() else { continue }
        await coordinator.handle(.accountStatus(account))
        await self?.ensurePiAlertSubscriptions(container)  // 账号切换后新账号的数据库里还没有订阅
      }
    }
  }

  public func stop() async {
    accountWatcher?.cancel()
    accountWatcher = nil
    await coordinator.stop()
    await queue.attach(nil)
    engine = nil
  }

  /// 立即拉取并推送（不等引擎的自动调度）。
  /// 只向服务器拉一次变化（不推送本机改动）：推送之外的主动拉取，见 `SyncPoller`。
  public func fetchChanges() async throws {
    try await engine?.fetchChanges()
  }

  public func syncNow() async throws {
    guard let engine else { return }
    try await engine.fetchChanges()
    try await engine.sendChanges()
  }

  private func ensurePiAlertSubscriptions(_ container: CKContainer) async {
    guard subscribesToPiAlerts else { return }
    do {
      try await PiAlertSubscriptions(zoneID: zoneID).ensure(in: DatabaseSubscriptions(database: container.privateCloudDatabase))
    } catch {
      await coordinator.note("Pi 通知订阅没能建立，下次启动或账号变化时重试：\(error.localizedDescription)")
    }
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
  let coordinator: SyncCoordinator
  let zoneID: CKRecordZone.ID

  init(coordinator: SyncCoordinator, zoneID: CKRecordZone.ID) {
    self.coordinator = coordinator
    self.zoneID = zoneID
  }

  func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    switch event {
    case .stateUpdate(let update):
      if let data = try? JSONEncoder().encode(update.stateSerialization) { await coordinator.handle(.stateUpdate(data)) }
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
