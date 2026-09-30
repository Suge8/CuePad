import CloudKit
import Foundation

/// iCloud 同步入口：私有数据库里一个自定义同步区，CKSyncEngine 驱动。
///
/// 用法：`let sync = CloudSync(store: store)`；`try await sync.start()`；界面订阅 `statusUpdates`，
/// 状态为 `.needsDecision` 时让用户选择后调用 `resolve(_:)`。冲突副本由 `CueStore.conflicts()` 提供。
/// 需要 App 带 iCloud（CloudKit）entitlement 与容器；没有 entitlement 的进程（命令行测试）不能调用 `start()`。
public actor CloudSync {
  private let store: CueStore
  private let containerIdentifier: String
  private let zoneID: CKRecordZone.ID
  private let queue = EngineQueue()
  private let coordinator: SyncCoordinator
  private var engine: CKSyncEngine?
  private var accountWatcher: Task<Void, Never>?

  public init(store: CueStore, containerIdentifier: String = "iCloud.com.sugeh.cuepad", zoneName: String = "CuePad") {
    self.store = store
    self.containerIdentifier = containerIdentifier
    zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    coordinator = SyncCoordinator(store: store, queue: queue, zoneID: zoneID)
  }

  public var status: SyncStatus { get async { await coordinator.status } }
  public var issues: [SyncIssue] { get async { await coordinator.issues } }
  /// 先给出当前状态，之后每次变化给出新状态。
  public nonisolated var statusUpdates: AsyncStream<SyncStatus> { coordinator.statusUpdates }

  public func start() async throws {
    guard engine == nil else { return }
    let container = CKContainer(identifier: containerIdentifier)
    await coordinator.handle(.accountStatus(try await container.accountStatus()))

    let saved = try await coordinator.savedEngineState()
    let state = saved.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
    let bridge = EngineBridge(coordinator: coordinator, zoneID: zoneID)
    let engine = CKSyncEngine(CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: state, delegate: bridge))
    self.engine = engine
    await queue.attach(engine)

    try await coordinator.start()
    accountWatcher = Task { [coordinator] in
      for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) {
        if let account = try? await container.accountStatus() { await coordinator.handle(.accountStatus(account)) }
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
  public func syncNow() async throws {
    guard let engine else { return }
    try await engine.fetchChanges()
    try await engine.sendChanges()
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
private final class EngineBridge: CKSyncEngineDelegate, Sendable {
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
