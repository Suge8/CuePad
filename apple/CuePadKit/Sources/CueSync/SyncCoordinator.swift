import CloudKit
import Foundation

/// 同步逻辑：待推送对账、远端变更应用、发送结果处理、账号与状态。
/// 不接触 CKSyncEngine；与引擎之间只有 `CloudEvent`（进）和 `ChangeQueue`、`record(for:)`（出）。
actor SyncCoordinator {
  private static let issueLimit = 50

  private let store: CueStore
  private let queue: any ChangeQueue
  private let zoneID: CKRecordZone.ID
  private let timing: Timing
  private let log: SyncTimingLog?
  private var fetchStartedAt: Date?
  private var watcher: Task<Void, Never>?
  private var subscribers: [UUID: AsyncStream<SyncState>.Continuation] = [:]

  private(set) var state = SyncState(status: .idle, issues: []) {
    didSet { if state != oldValue { for continuation in subscribers.values { continuation.yield(state) } } }
  }
  private(set) var status: SyncStatus {
    get { state.status }
    set { state.status = newValue }
  }
  var issues: [SyncIssue] { state.issues }

  init(store: CueStore, queue: any ChangeQueue, zoneID: CKRecordZone.ID, timing: Timing = .system, log: SyncTimingLog? = nil) {
    self.store = store
    self.queue = queue
    self.zoneID = zoneID
    self.timing = timing
    self.log = log
  }

  // MARK: 状态订阅

  /// 先给出当前快照，之后状态或问题列表每次变化给出新快照。
  nonisolated var stateUpdates: AsyncStream<SyncState> {
    AsyncStream { continuation in
      let token = UUID()
      Task {
        await self.subscribe(token, continuation)
        continuation.onTermination = { _ in Task { await self.unsubscribe(token) } }
      }
    }
  }

  private func subscribe(_ token: UUID, _ continuation: AsyncStream<SyncState>.Continuation) {
    subscribers[token] = continuation
    continuation.yield(state)
  }

  private func unsubscribe(_ token: UUID) { subscribers[token] = nil }

  // MARK: 生命周期

  /// 登记同步区、对账一次，并从此在每次本机写入提交后对账。
  func start() async throws {
    await queue.ensureZone(zoneID)
    try await reconcile()
    watcher = Task { [store] in
      do {
        for try await _ in store.observe(Set(Table.synced), { _ in () }) {
          do { try await self.reconcile() } catch { await self.report(error, recordName: nil) }
        }
      } catch {
        await self.report(error, recordName: nil)
      }
    }
  }

  func stop() {
    watcher?.cancel()
    watcher = nil
  }

  /// 待推送 = 数据库推导：从未推送过或推送后又改过的记录；服务器有而本机已不在的记录（删除）。
  /// 本次尚未成功的推送在引擎里丢了也没关系，下一次对账会重新登记。
  func reconcile() async throws {
    guard needsDecision == nil else { return }
    let pending = try await store.pendingSync()
    guard !pending.saves.isEmpty || !pending.deletes.isEmpty else { return }
    await queue.enqueue(saves: pending.saves.map { recordID($0.id) }, deletes: pending.deletes.map(recordID))
  }

  /// 引擎要发送某条记录时构造它：以上次服务器记录的系统字段为底，写入当前行的字段；行已不在则返回 nil（引擎丢弃该待办）。
  func record(for id: CKRecord.ID) async -> CKRecord? {
    do {
      guard let row = try await store.syncRow(recordName: id.recordName) else { return nil }
      let base = try await store.systemFields(of: id.recordName).flatMap(RecordMapper.decodeSystemFields)
      let record = RecordMapper.record(from: row, zoneID: zoneID, base: base)
      if row.table == .attachments {
        guard case .text(let hash)? = row.fields["hash"], let file = store.files.url(hash: hash) else {
          report("附件文件不在本机，未上传", recordType: row.table.rawValue, recordName: id.recordName)
          return nil
        }
        record["file"] = CKAsset(fileURL: file)
      }
      return record
    } catch {
      report(error, recordName: id.recordName)
      return nil
    }
  }

  /// 记一条不影响状态的事项（如订阅创建失败，下次启动或账号变化时会重试）。
  func note(_ message: String) { report(message, recordType: nil, recordName: nil) }

  func savedEngineState() async throws -> Data? { try await store.engineState() }

  /// 用户对 `needsDecision` 的选择。之后需要重建引擎（引擎状态属于旧账号或已失效的云端数据，这里已清掉）。
  func resolve(_ resolution: SyncResolution) async throws {
    guard needsDecision != nil else { throw SyncError.nothingToResolve }
    switch resolution {
    case .uploadLocal: try await store.resetSyncMetadata()
    case .eraseLocal: try await store.eraseSyncedData()
    }
    status = .idle
    await queue.ensureZone(zoneID)
    try await reconcile()
  }

  // MARK: 事件

  func handle(_ event: CloudEvent) async {
    do { try await process(event) } catch { report(error, recordName: nil) }
  }

  private func process(_ event: CloudEvent) async throws {
    switch event {
    case .stateUpdate(let data):
      try await store.setEngineState(data)
    case .accountStatus(let account):
      accountStatus(account)
    case .accountChange(let change):
      try await accountChange(change)
    case .cloudDataLost(let loss):
      status = .needsDecision(loss == .deleted ? .cloudDataDeleted : .cloudDataReset)
    case .fetchStarted:
      fetchStartedAt = timing.now()
    case .syncing(let busy):
      if busy, status == .idle { status = .syncing }
      if !busy, status == .syncing { status = .idle }
    case .fetched(let modifications, let deletions):
      guard needsDecision == nil else { return }
      let startedAt = fetchStartedAt
      fetchStartedAt = nil
      try await applyFetched(modifications, deletions)
      await log?.recordFetch(modifications.map(\.recordID.recordName), startedAt: startedAt, appliedAt: timing.now())
      if case .failed = status { status = .idle }
      try await reconcile()
    case .sent(let saved, let failedSaves, let deleted, let failedDeletes):
      guard needsDecision == nil else { return }
      try await processSent(saved, failedSaves, deleted, failedDeletes)
    case .zoneSaveFailed(let error):
      classify(error, recordName: nil)
    }
  }

  private var needsDecision: SyncDecision? {
    if case .needsDecision(let decision) = status { decision } else { nil }
  }

  private func accountStatus(_ account: CKAccountStatus) {
    guard needsDecision == nil else { return }
    switch account {
    case .available:
      if [.noAccount, .accountRestricted, .accountUnavailable].contains(status) { status = .idle }
    case .noAccount: status = .noAccount
    case .restricted: status = .accountRestricted
    case .temporarilyUnavailable, .couldNotDetermine: status = .accountUnavailable
    @unknown default: status = .accountUnavailable
    }
  }

  private func accountChange(_ change: AccountChange) async throws {
    switch change {
    case .signedOut:
      status = .noAccount
    case .signedIn:
      // 新登录的账号：云端记录与本机记录的对应关系从零开始，本机全部重新上传。
      try await store.resetSyncMetadata()
      status = .idle
      try await reconcile()
    case .switched:
      status = .needsDecision(.accountSwitched)
    }
  }

  // MARK: 远端变更

  private func applyFetched(_ modifications: [CKRecord], _ deletions: [(id: CKRecord.ID, recordType: String)]) async throws {
    var changes: [RemoteChange] = []
    for record in modifications {
      guard let row = RecordMapper.row(from: record) else {
        report("未知的记录类型「\(record.recordType)」，已跳过（可能来自更新版本的 CuePad）", recordType: record.recordType, recordName: record.recordID.recordName)
        continue
      }
      if row.table == .attachments, !adoptAsset(of: record, row) { continue }
      changes.append(.save(row, systemFields: RecordMapper.encodeSystemFields(record)))
    }
    for (id, recordType) in deletions {
      guard let table = RecordMapper.table(named: recordType) else {
        report("未知的记录类型「\(recordType)」的删除，已跳过", recordType: recordType, recordName: id.recordName)
        continue
      }
      changes.append(.delete(SyncKey(table: table, id: id.recordName)))
    }
    for failure in try await store.applyRemote(changes) {
      report(failure.message, recordType: nil, recordName: failure.recordName)
    }
  }

  /// 附件记录必须带文件且内容与哈希一致，才把文件放进附件目录；否则拒绝这条记录并报告。
  private func adoptAsset(of record: CKRecord, _ row: SyncRow) -> Bool {
    let name = record.recordID.recordName
    guard case .text(let hash)? = row.fields["hash"], let file = (record["file"] as? CKAsset)?.fileURL else {
      report("附件记录没有文件，已拒绝", recordType: record.recordType, recordName: name)
      return false
    }
    do {
      try store.files.adopt(fileAt: file, hash: hash)
      return true
    } catch {
      report("附件文件校验失败，已拒绝：\(error)", recordType: record.recordType, recordName: name)
      return false
    }
  }

  // MARK: 发送结果

  private func processSent(
    _ saved: [CKRecord], _ failedSaves: [(record: CKRecord, error: CKError)], _ deleted: [CKRecord.ID],
    _ failedDeletes: [(id: CKRecord.ID, error: CKError)]
  ) async throws {
    for record in saved {
      guard let row = RecordMapper.row(from: record) else { continue }
      try await store.markPushed(row, systemFields: RecordMapper.encodeSystemFields(record))
    }
    await log?.recordSend(saved.map(\.recordID.recordName), at: timing.now())
    for id in deleted { try await store.dropSyncMetadata(id.recordName) }

    var blocked = false
    for (record, error) in failedSaves {
      switch error.code {
      case .serverRecordChanged:
        if let server = error.serverRecord {
          try await applyFetched([server], [])
        } else {
          report("保存冲突但没有服务器版本：\(error)", recordType: record.recordType, recordName: record.recordID.recordName)
        }
      case .unknownItem, .zoneNotFound:
        // 服务器上没有这条记录（或整个同步区没了）：忘掉旧系统字段，作为新记录重新上传。
        if error.code == .zoneNotFound { await queue.ensureZone(zoneID) }
        try await store.dropSyncMetadata(record.recordID.recordName)
      default:
        blocked = classify(error, recordName: record.recordID.recordName) || blocked
      }
    }
    for (id, error) in failedDeletes {
      if error.code == .unknownItem {
        try await store.dropSyncMetadata(id.recordName)
      } else {
        blocked = classify(error, recordName: id.recordName) || blocked
      }
    }

    if !saved.isEmpty, failedSaves.isEmpty, failedDeletes.isEmpty, needsDecision == nil { status = .idle }
    // 停在配额或未预期失败时不立刻重新登记（会空转）；下一次本机写入或启动时对账会重试。
    if !blocked { try await reconcile() }
  }

  /// 把 CloudKit 错误映射到状态。返回 true 表示这类失败不应立刻重试。瞬时网络类错误交给引擎自己重试。
  @discardableResult
  private func classify(_ error: CKError, recordName: String?) -> Bool {
    switch error.code {
    case .quotaExceeded:
      status = .quotaExceeded
      return true
    case .notAuthenticated:
      status = .noAccount
      return true
    case .networkFailure, .networkUnavailable, .serviceUnavailable, .zoneBusy, .requestRateLimited,
      .batchRequestFailed, .operationCancelled:
      return false
    default:
      report(error, recordName: recordName)
      return true
    }
  }

  // MARK: 报告

  private func report(_ error: Error, recordName: String?) {
    report("\(error.localizedDescription)（\(error)）", recordType: nil, recordName: recordName, failed: true)
  }

  private func report(_ message: String, recordType: String?, recordName: String?, failed: Bool = false) {
    var next = state
    next.issues.append(SyncIssue(recordType: recordType, recordName: recordName, message: message))
    if next.issues.count > Self.issueLimit { next.issues.removeFirst(next.issues.count - Self.issueLimit) }
    if failed, needsDecision == nil { next.status = .failed(message) }
    state = next  // 问题与状态一次送达
  }

  private func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }
}
