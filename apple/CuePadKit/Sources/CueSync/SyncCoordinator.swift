import CloudKit
import Foundation
import os

/// 同步逻辑：待推送对账、远端变更应用、发送结果处理、账号与状态。
/// 不接触 CKSyncEngine；与引擎之间只有 `CloudEvent`（进）和 `ChangeQueue`、`record(for:)`（出）。
actor SyncCoordinator {
  private static let issueLimit = 50
  private static let sendNowAttempts = 3
  private static let log = Logger(subsystem: "com.sugeh.cuepad", category: "delivery")

  let store: CueStore
  private let queue: any ChangeQueue
  private let zoneID: CKRecordZone.ID
  private var watcher: Task<Void, Never>?
  /// 有登记被搁置（配额、未预期失败）：下一次本机改动时全量对账一次，把它们重新登记。
  private var needsFullReconcile = false
  /// 服务器上的大字段（见 `ServerValues`）。已交出去、还没有结果的上传版本记在库里（`CueStore.noteSent`）：结果回来时用它记账，
  /// 不读服务器返回的记录（返回的记录只带发出去的字段）；引擎的上传与立即上传可以重叠，同一条记录会有几个版本在路上，
  /// 按修改时间区分，结果回来时取它自己那一版。
  private var serverValues = ServerValues()
  private var subscribers: [UUID: AsyncStream<SyncState>.Continuation] = [:]

  private(set) var state = SyncState(status: .starting, issues: []) {
    didSet { if state != oldValue { for continuation in subscribers.values { continuation.yield(state) } } }
  }
  private(set) var status: SyncStatus {
    get { state.status }
    set { state.status = newValue }
  }
  var issues: [SyncIssue] { state.issues }

  init(store: CueStore, queue: any ChangeQueue, zoneID: CKRecordZone.ID) {
    self.store = store
    self.queue = queue
    self.zoneID = zoneID
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

  /// 登记同步区、全量对账一次，之后每次本机提交只登记它改动的记录。
  func start() async throws {
    await queue.ensureZone(zoneID)
    let changes = await store.syncChanges()  // 先订阅再对账：两者之间的写入不会漏
    try await reconcile()
    watcher = Task {
      for await change in changes {
        do { try await self.register(change) } catch { self.report(error, recordName: nil) }
      }
    }
  }

  func stop() {
    watcher?.cancel()
    watcher = nil
  }

  /// 全量对账。待推送 = 数据库推导：从未推送过或推送后又改过的记录；服务器有而本机已不在的记录（删除）。
  /// 本次尚未成功的推送在引擎里丢了也没关系，下一次对账会重新登记。
  func reconcile() async throws {
    guard needsDecision == nil else { return }
    needsFullReconcile = false
    await enqueue(try await store.pendingSync())
  }

  /// 一次本机提交的增量；nil（改动范围未知）或此前有搁置的登记时全量对账。
  private func register(_ change: PendingSync?) async throws {
    guard needsDecision == nil else { return }
    guard let change, !needsFullReconcile else { return try await reconcile() }
    await enqueue(change)
  }

  private func enqueue(_ pending: PendingSync) async {
    guard !pending.saves.isEmpty || !pending.deletes.isEmpty else { return }
    await queue.enqueue(saves: pending.saves.map { recordID($0.id) }, deletes: pending.deletes.map(recordID))
  }

  /// 引擎要发送某条记录时构造它：以上次服务器记录的系统字段为底，写入当前行的字段；行已不在则返回 nil（引擎丢弃该待办）。
  func record(for id: CKRecord.ID) async -> CKRecord? {
    do {
      guard let row = try await store.syncRow(recordName: id.recordName) else { return nil }
      let base = try await store.systemFields(of: id.recordName).flatMap(RecordMapper.decodeSystemFields)
      let values = serverValues
      let record = RecordMapper.record(from: row, zoneID: zoneID, base: base, isCurrent: { base != nil && values.isCurrent($0, in: row) })
      if row.table == .attachments {
        guard case .text(let hash)? = row.fields["hash"], let file = store.files.fileURL(for: hash) else {
          report("附件文件不在本机，未上传", recordType: row.table.rawValue, recordName: id.recordName)
          return nil
        }
        record["file"] = CKAsset(fileURL: file)
      }
      try await store.noteSent(row)  // 取了没发出去的版本不会有结果，留到这条记录下一次落账时清掉
      return record
    } catch {
      report(error, recordName: id.recordName)
      return nil
    }
  }

  /// 立即把一条记录直接存到服务器（不经引擎的队列，见 `RecordUploader`）；结果与引擎发送的结果同一个入口处理。
  /// 整个请求失败（离线）时抛出；返回服务器是否收下了这一条（没收下的，调用方要把它交回引擎重试）。
  /// 上传期间本机又改过这条记录的话，结果入口已为更新的版本登记待办，调用方不能把它清掉。
  /// 引擎可能刚把这条记录的上一版传上去、结果还在路上，本机带的版本标签就是旧的，服务器以 `serverRecordChanged` 拒绝：
  /// 结果入口已经记下服务器的版本与新标签，这里马上带着它重传（回落引擎要多等一轮调度），本机版本比服务器的旧就不用传了。
  func sendNow(_ id: CKRecord.ID, deleted: Bool, via uploader: any RecordUploader) async throws -> SendNowResult {
    for _ in 0..<Self.sendNowAttempts {
      guard needsDecision == nil else { return .received }
      let saving = deleted ? nil : await record(for: id)
      guard deleted || saving != nil else { return .received }  // 行已不在：没有可传的
      let sent = try await attempt(saving.map { [$0] } ?? [], deleting: deleted ? [id] : [], via: uploader)
      await handle(.sent(saved: sent.saved, failedSaves: sent.failedSaves, deleted: sent.deleted, failedDeletes: sent.failedDeletes))
      if sent.saved.contains(where: { $0.recordID == id }) || sent.deleted.contains(id) {
        return try await store.isPending(id.recordName) ? .receivedWithNewerVersionPending : .received
      }
      let superseded = sent.failedSaves.contains { $0.record.recordID == id && $0.error.code == .serverRecordChanged }
      guard superseded else { return .rejected }
      if try await !store.isPending(id.recordName) { return .received }  // 服务器的版本更新，已留下
    }
    return .rejected
  }

  /// 一次直接上传；没收下的与整个请求的失败都带着服务器给的原因记日志（错误码与说明不含个人内容）。
  private func attempt(_ saving: [CKRecord], deleting: [CKRecord.ID], via uploader: any RecordUploader) async throws -> SentRecords {
    do {
      let sent = try await uploader.upload(saving: saving, deleting: deleting)
      for (record, error) in sent.failedSaves { Self.logRejected(record.recordID, error) }
      for (id, error) in sent.failedDeletes { Self.logRejected(id, error) }
      return sent
    } catch {
      Self.log.notice("立即上传整个请求失败：\(error.brief, privacy: .public)")
      throw error
    }
  }

  private static func logRejected(_ id: CKRecord.ID, _ error: CKError) {
    log.notice("立即上传被服务器拒绝 \(id.recordName.prefix(8), privacy: .public)：\(error.brief, privacy: .public)")
  }

  var alertSubscription: PiAlertSubscriptionStatus { state.alerts }
  func setAlerts(_ alerts: PiAlertSubscriptionStatus) { state.alerts = alerts }

  func savedEngineState() async throws -> Data? { try await store.engineState() }

  /// 用户对 `needsDecision` 的选择。之后需要重建引擎（引擎状态属于旧账号或已失效的云端数据，这里已清掉）。
  func resolve(_ resolution: SyncResolution) async throws {
    guard needsDecision != nil else { throw SyncError.nothingToResolve }
    serverValues.removeAll()
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
    case .syncing(let busy):
      if busy, status == .idle { status = .syncing }
      if !busy, status == .syncing { status = .idle }
    case .fetched(let modifications, let deletions):
      guard needsDecision == nil else { return }
      try await applyFetched(modifications, deletions)  // 应用时的改动（本机胜出的版本、冲突副本）经提交增量登记
      if case .failed = status { status = .idle }
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
      if [.starting, .noAccount, .accountRestricted, .accountUnavailable].contains(status) { status = .idle }
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
      serverValues.removeAll()
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
    for record in modifications where !CloudKitSchema.retiredTypeNames.contains(record.recordType) {
      guard let row = RecordMapper.row(from: record) else {
        report("未知的记录类型「\(record.recordType)」，已跳过（可能来自更新版本的 CuePad）", recordType: record.recordType, recordName: record.recordID.recordName)
        continue
      }
      serverValues.learn(row)  // 服务器上就是这个样子，不管本机最后留下哪个版本
      if row.table == .deliveryRequests { traceArrival(of: record, row) }
      if row.table == .attachments, !adoptAsset(of: record, row) { continue }
      changes.append(.save(row, systemFields: RecordMapper.encodeSystemFields(record)))
    }
    for (id, recordType) in deletions where !CloudKitSchema.retiredTypeNames.contains(recordType) {
      guard let table = RecordMapper.table(named: recordType) else {
        report("未知的记录类型「\(recordType)」的删除，已跳过", recordType: recordType, recordName: id.recordName)
        continue
      }
      serverValues.forget(id.recordName)
      changes.append(.delete(SyncKey(table: table, id: id.recordName)))
    }
    for failure in try await store.applyRemote(changes) {
      report(failure.message, recordType: nil, recordName: failure.recordName)
    }
  }

  /// 投送请求（及其结果）到达的时间线：创建 → 服务器（对端上传用了多久）→ 本机（拉取用了多久）。
  private func traceArrival(of record: CKRecord, _ row: SyncRow) {
    guard case .int(let created)? = row.fields["createdAt"], case .text(let status)? = row.fields["status"],
      let stored = record.modificationDate
    else { return }
    let toServer = stored.timeIntervalSince(Date(timeIntervalSince1970: Double(created) / 1000))
    Self.log.info(
      "投送请求到达 \(record.recordID.recordName.prefix(8), privacy: .public) \(status, privacy: .public)：创建后 \(toServer, format: .fixed(precision: 1)) 秒到服务器，再 \(Date.now.timeIntervalSince(stored), format: .fixed(precision: 1)) 秒到本机")
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

  /// 这条记录发出去的那一版（发出去的记录和服务器返回的记录都带着当时的 `modifiedAt`）；落账时才从库里清掉。
  private func sentRow(_ record: CKRecord) async throws -> SyncRow? {
    guard let stamp = (record["modifiedAt"] as? NSNumber)?.int64Value else { return nil }
    return try await store.sentRow(recordName: record.recordID.recordName, modifiedAt: stamp)
  }

  private func processSent(
    _ saved: [CKRecord], _ failedSaves: [(record: CKRecord, error: CKError)], _ deleted: [CKRecord.ID],
    _ failedDeletes: [(id: CKRecord.ID, error: CKError)]
  ) async throws {
    var changedSince: [CKRecord.ID] = []
    for record in saved {
      // 每一版发出前都记进了 syncSent，读不到只会是更新的一版已经落账、把它清掉了：这条结果已过时，不记账
      guard let row = try await sentRow(record) else { continue }
      serverValues.learn(row)
      // 引擎发送的是取走时的版本；之后又改过的，引擎已移除它的待办，要重新登记
      if try await store.markPushed(row, systemFields: RecordMapper.encodeSystemFields(record)) { changedSince.append(record.recordID) }
    }
    var resend = changedSince
    var resendDeletes: [CKRecord.ID] = []
    for id in deleted {
      serverValues.forget(id.recordName)
      try await store.dropSyncMetadata(id.recordName)
    }

    var blocked = false
    for (record, error) in failedSaves {
      switch error.code {
      case .serverRecordChanged:
        if let server = error.serverRecord {
          try await applyFetched([server], [])
          // 本机版本胜出时它仍是待推送，引擎已移除它的待办
          if try await store.isPending(record.recordID.recordName) { resend.append(record.recordID) }
        } else {
          report("保存冲突但没有服务器版本：\(error)", recordType: record.recordType, recordName: record.recordID.recordName)
        }
      case .batchRequestFailed:
        // 同批里别的记录被拒，这条自己没问题；引擎不会替它重试
        resend.append(record.recordID)
      case .unknownItem, .zoneNotFound:
        // 服务器上没有这条记录（或整个同步区没了）：忘掉旧系统字段，作为新记录重新上传。
        if error.code == .zoneNotFound { await queue.ensureZone(zoneID) }
        serverValues.forget(record.recordID.recordName)
        try await store.dropSyncMetadata(record.recordID.recordName)
        resend.append(record.recordID)
      default:
        blocked = classify(error, recordType: record.recordType, recordName: record.recordID.recordName) || blocked
      }
    }
    for (id, error) in failedDeletes {
      if error.code == .unknownItem {
        try await store.dropSyncMetadata(id.recordName)
      } else if error.code == .batchRequestFailed {
        resendDeletes.append(id)
      } else {
        blocked = classify(error, recordName: id.recordName) || blocked
      }
    }

    if !saved.isEmpty, failedSaves.isEmpty, failedDeletes.isEmpty, needsDecision == nil { status = .idle }
    // 停在配额或未预期失败时不立刻重新登记（会空转）；下一次本机写入时全量对账重试。
    if blocked { needsFullReconcile = true }
    if !resend.isEmpty || !resendDeletes.isEmpty { await queue.enqueue(saves: resend, deletes: resendDeletes) }
  }

  /// 把 CloudKit 错误映射到状态。返回 true 表示这类失败不应立刻重试。瞬时网络类错误交给引擎自己重试。
  @discardableResult
  private func classify(_ error: CKError, recordType: String? = nil, recordName: String?) -> Bool {
    switch error.code {
    case .quotaExceeded:
      status = .quotaExceeded
      return true
    case .notAuthenticated:
      status = .noAccount
      return true
    case .networkFailure, .networkUnavailable, .serviceUnavailable, .zoneBusy, .requestRateLimited, .operationCancelled:
      return false
    default:
      report(error, recordType: recordType, recordName: recordName)
      return true
    }
  }

  // MARK: 报告

  private func report(_ error: Error, recordType: String? = nil, recordName: String?) {
    report(error.diagnosis, recordType: recordType, recordName: recordName, failed: true)
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
