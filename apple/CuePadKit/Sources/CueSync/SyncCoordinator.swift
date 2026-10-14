import CloudKit
import Foundation
import os

/// 同步逻辑：远端变更应用、上传批次与结果处理、账号与状态。不碰网络：拉取器（`ZonePuller`）与发送者（`RecordSender`）
/// 把服务器给的交进来（`CloudEvent`），发送者从这里取下一批（`nextBatch`）。待推送只有库里推导的一份（`CueStore.pendingSync`）。
actor SyncCoordinator {
  private static let issueLimit = 50
  private static let log = Logger(subsystem: "com.sugeh.cuepad", category: "delivery")
  static let accountKey = "account"

  let store: CueStore
  nonisolated let zoneID: CKRecordZone.ID
  private var subscribers: [UUID: AsyncStream<SyncState>.Continuation] = [:]
  /// 构造不出来的记录（附件文件不在本机）与当时的修改时间：同一版不再每批重试、重复报告，改过再试。
  private var unsendable: [String: Int64] = [:]
  private var sending = false
  private var catchingUp = false

  private(set) var state = SyncState(status: .starting, issues: []) {
    didSet { if state != oldValue { for continuation in subscribers.values { continuation.yield(state) } } }
  }
  private(set) var status: SyncStatus {
    get { state.status }
    set { state.status = newValue }
  }
  var issues: [SyncIssue] { state.issues }

  init(store: CueStore, zoneID: CKRecordZone.ID) {
    self.store = store
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

  /// 能不能和服务器同步：有可用的账号，也没有停下来等你决定。
  var canSync: Bool {
    needsDecision == nil && ![.noAccount, .accountRestricted].contains(status)
  }

  var alertSubscription: PiAlertSubscriptionStatus { state.alerts }
  func setAlerts(_ alerts: PiAlertSubscriptionStatus) { state.alerts = alerts }

  /// 用户对 `needsDecision` 的选择。之后重新开始同步（元数据、令牌与账号这里已清掉）。
  func resolve(_ resolution: SyncResolution) async throws {
    guard needsDecision != nil else { throw SyncError.nothingToResolve }
    switch resolution {
    case .uploadLocal: try await store.resetSyncMetadata()
    case .eraseLocal: try await store.eraseSyncedData()
    }
    unsendable = [:]
    status = .idle
  }

  // MARK: 上传批次

  /// 下一批要上传的：`first` 里待推送的排在前面，至多 `limit` 条；没有可传的（或此刻不能同步）为 nil。
  func nextBatch(first: Set<String>, limit: Int) async -> (saves: [CKRecord], deletes: [CKRecord.ID])? {
    guard canSync else { return nil }
    let pending: PendingSync
    do { pending = try await store.pendingSync() } catch {
      report(error, recordName: nil)
      return nil
    }
    let names = pending.saves.map(\.id).filter { unsendable[$0] == nil }
    let ordered = names.filter(first.contains) + names.filter { !first.contains($0) }
    let deletes = pending.deletes.filter(first.contains) + pending.deletes.filter { !first.contains($0) }
    var saves: [CKRecord] = []
    for name in ordered where saves.count < limit {
      if let record = await record(for: recordID(name)) { saves.append(record) }
    }
    let batch = (saves: saves, deletes: Array(deletes.prefix(limit - saves.count)).map(recordID))
    guard !batch.saves.isEmpty || !batch.deletes.isEmpty else { return nil }
    do {
      try await store.noteSent(saves.compactMap { record in
        guard let table = RecordMapper.table(named: record.recordType), let stamp = (record["modifiedAt"] as? NSNumber)?.int64Value else { return nil }
        return (record.recordID.recordName, table, stamp)
      })
    } catch {
      report(error, recordName: nil)
      return nil
    }
    return batch
  }

  /// 构造要上传的记录：以上次服务器记录的系统字段为底，写入当前行的字段；行已不在则返回 nil。
  func record(for id: CKRecord.ID) async -> CKRecord? {
    do {
      guard let row = try await store.syncRow(recordName: id.recordName) else { return nil }
      let base = try await store.systemFields(of: id.recordName).flatMap(RecordMapper.decodeSystemFields)
      let record = RecordMapper.record(from: row, zoneID: zoneID, base: base)
      if row.table == .attachments {
        guard case .text(let hash)? = row.fields["hash"], let file = store.files.fileURL(for: hash) else {
          unsendable[id.recordName] = row.modifiedAt
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

  // MARK: 事件

  func handle(_ event: CloudEvent) async {
    do { try await process(event) } catch { report(error, recordName: nil) }
  }

  private func process(_ event: CloudEvent) async throws {
    switch event {
    case .accountStatus(let account):
      accountStatus(account)
    case .account(let name):
      try await account(name)
    case .zoneMissing(let deletedByUser):
      try await zoneMissing(deletedByUser: deletedByUser)
    case .sending(let busy):
      sending = busy
      showActivity()
    case .catchingUp(let busy):
      catchingUp = busy
      showActivity()
    case .fetched(let modifications, let deletions):
      guard needsDecision == nil else { return }
      try await applyFetched(modifications, deletions)  // 应用时的改动（本机胜出的版本、冲突副本）留在库里待推送
      if case .failed = status { status = .idle }
    case .sent(let sent):
      guard needsDecision == nil else { return }
      _ = try await processSent(sent)
    }
  }

  /// 拉取器拉到的一页：应用完才返回；整页没能应用（库写不进去、停下来等你决定）时抛出，拉取器不前移令牌。
  /// 单条记录不合法只报告（见 `ZonePuller`）。
  func pulled(_ modifications: [CKRecord], _ deletions: [(id: CKRecord.ID, recordType: String)]) async throws {
    guard needsDecision == nil else { throw SyncPaused() }
    guard !modifications.isEmpty || !deletions.isEmpty else { return }
    do {
      try await applyFetched(modifications, deletions)
    } catch {
      report(error, recordName: nil)
      throw error
    }
    if case .failed = status { status = .idle }
  }

  /// 上传结果：记账，并告诉发送者这批有没有进展、要不要停下来等。
  func sent(_ sent: SentRecords) async -> SendOutcome {
    guard needsDecision == nil else { return SendOutcome(progressed: false, blocked: true, zoneMissing: false) }
    do {
      return try await processSent(sent)
    } catch {
      report(error, recordName: nil)
      return SendOutcome(progressed: false, blocked: true, zoneMissing: false)
    }
  }

  /// 整个上传请求失败（不是单条记录被拒）且不会自己好起来：记下原因与状态。
  func uploadFailed(_ error: CKError) {
    classify(error, recordName: nil)
  }

  private func showActivity() {
    let busy = sending || catchingUp
    if busy, status == .idle { status = .syncing }
    if !busy, status == .syncing { status = .idle }
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

  /// 此刻登录的 iCloud 账号（用户记录名）。第一次同步（含从 CKSyncEngine 的版本升上来）记下；和上次同步的不是同一个时，
  /// 本机数据属于上一个账号，停下来等你决定。
  private func account(_ name: String) async throws {
    guard needsDecision == nil else { return }
    let current = Data(name.utf8)
    guard let last = try await store.syncState(Self.accountKey) else { return try await store.setSyncState(Self.accountKey, current) }
    if last != current { status = .needsDecision(.accountSwitched) }
  }

  /// 同步区不在了：同步过的（有令牌或推送过的记录）是云端数据被删除或重置，停下来等你决定；从没同步过的不用管，第一次上传时建区。
  private func zoneMissing(deletedByUser: Bool) async throws {
    guard needsDecision == nil else { return }
    let hadToken = try await store.syncState(ZonePuller.tokenKey) != nil
    let pushedAny = try await !store.syncedRecords().isEmpty
    let synced = hadToken || pushedAny
    try await store.setSyncState(ZonePuller.tokenKey, nil)
    if synced { status = .needsDecision(deletedByUser ? .cloudDataDeleted : .cloudDataReset) }
  }

  // MARK: 远端变更

  private func applyFetched(_ modifications: [CKRecord], _ deletions: [(id: CKRecord.ID, recordType: String)]) async throws {
    var changes: [RemoteChange] = []
    for record in modifications where !CloudKitSchema.retiredTypeNames.contains(record.recordType) {
      guard let row = RecordMapper.row(from: record) else {
        report("未知的记录类型「\(record.recordType)」，已跳过（可能来自更新版本的 CuePad）", recordType: record.recordType, recordName: record.recordID.recordName)
        continue
      }
      if row.table == .deliveryRequests { traceArrival(of: record, row) }
      if row.table == .attachments, try !adoptAsset(of: record, row) { continue }
      changes.append(.save(row, systemFields: RecordMapper.encodeSystemFields(record)))
    }
    for (id, recordType) in deletions where !CloudKitSchema.retiredTypeNames.contains(recordType) {
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

  /// 投送请求（及其结果）到达的时间线：创建 → 服务器（对端上传用了多久）→ 本机（拉取用了多久）。
  private func traceArrival(of record: CKRecord, _ row: SyncRow) {
    guard case .int(let created)? = row.fields["createdAt"], case .text(let status)? = row.fields["status"],
      let stored = record.modificationDate
    else { return }
    let toServer = stored.timeIntervalSince(Date(timeIntervalSince1970: Double(created) / 1000))
    Self.log.info(
      "投送请求到达 \(record.recordID.recordName.prefix(8), privacy: .public) \(status, privacy: .public)：创建后 \(toServer, format: .fixed(precision: 1)) 秒到服务器，再 \(Date.now.timeIntervalSince(stored), format: .fixed(precision: 1)) 秒到本机")
  }

  /// 附件记录必须带文件且内容与哈希一致，才把文件放进附件目录；记录本身坏了拒绝这条记录并报告（返回 false）。
  /// 本机写不进去（读下载的文件、建目录、拷贝、改名失败）抛出：这一页没应用完，拉取器不前移令牌，之后再拉。
  private func adoptAsset(of record: CKRecord, _ row: SyncRow) throws -> Bool {
    let name = record.recordID.recordName
    guard case .text(let hash)? = row.fields["hash"], let file = (record["file"] as? CKAsset)?.fileURL else {
      report("附件记录没有文件，已拒绝", recordType: record.recordType, recordName: name)
      return false
    }
    do {
      try store.files.adopt(fileAt: file, hash: hash)
      return true
    } catch let error as CueStoreError where [.invalidAttachmentHash, .attachmentHashMismatch].contains(error) {
      report("附件文件校验失败，已拒绝：\(error)", recordType: record.recordType, recordName: name)
      return false
    }
  }

  // MARK: 发送结果

  private func processSent(_ sent: SentRecords) async throws -> SendOutcome {
    var outcome = SendOutcome(progressed: !sent.saved.isEmpty || !sent.deleted.isEmpty, blocked: false, zoneMissing: false)
    for record in sent.saved {
      guard let row = RecordMapper.row(from: record) else { continue }
      try await store.markPushed(row, systemFields: RecordMapper.encodeSystemFields(record))
    }
    for id in sent.deleted { try await store.dropSyncMetadata(id.recordName) }

    // 没收下的仍是待推送（库里推导），下一批自然带上；这里只处理要先改本机状态才能成功的
    for (record, error) in sent.failedSaves {
      let name = record.recordID.recordName
      switch error.code {
      case .serverRecordChanged:
        if let server = error.serverRecord {
          try await applyFetched([server], [])  // 带上服务器的版本标签；本机版本胜出的话下一批重传
          outcome.progressed = true
        } else {
          report("保存冲突但没有服务器版本：\(error)", recordType: record.recordType, recordName: name)
        }
      case .batchRequestFailed:
        outcome.progressed = true  // 同批里别的记录被拒，这条自己没问题
      case .unknownItem, .zoneNotFound:
        // 服务器上没有这条记录（或整个同步区没了）：忘掉旧系统字段，作为新记录重新上传
        if error.code == .zoneNotFound { outcome.zoneMissing = true }
        try await store.dropSyncMetadata(name)
        outcome.progressed = true
      default:
        outcome.blocked = classify(error, recordType: record.recordType, recordName: name) || outcome.blocked
        outcome.wait(for: error)
      }
    }
    for (id, error) in sent.failedDeletes {
      switch error.code {
      case .unknownItem:
        try await store.dropSyncMetadata(id.recordName)
        outcome.progressed = true
      case .batchRequestFailed: outcome.progressed = true
      case .zoneNotFound:
        try await store.dropSyncMetadata(id.recordName)
        outcome.progressed = true
      default:
        outcome.blocked = classify(error, recordName: id.recordName) || outcome.blocked
        outcome.wait(for: error)
      }
    }
    // 收下了：之前的失败与空间不足都过去了
    if !sent.saved.isEmpty || !sent.deleted.isEmpty, sent.failedSaves.isEmpty, sent.failedDeletes.isEmpty, status.isSettledFailure {
      status = sending ? .syncing : .idle
    }
    return outcome
  }

  /// 把 CloudKit 错误映射到状态。返回 true 表示这类失败不应立刻重试。瞬时网络类错误由发送者退避重试（RecordSender）。
  @discardableResult
  private func classify(_ error: CKError, recordType: String? = nil, recordName: String?) -> Bool {
    switch error.code {
    case .quotaExceeded:
      status = .quotaExceeded
      return true
    case .notAuthenticated:
      status = .noAccount
      return true
    case .networkFailure, .networkUnavailable, .serviceUnavailable, .zoneBusy, .requestRateLimited, .operationCancelled,
      .serverResponseLost, .accountTemporarilyUnavailable, .limitExceeded:
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
    let issue = SyncIssue(recordType: recordType, recordName: recordName, message: message)
    // 停下后每次重试都会再报同一个错：问题列表里已有的不再加，免得被它刷满
    if !next.issues.contains(issue) { next.issues.append(issue) }
    if next.issues.count > Self.issueLimit { next.issues.removeFirst(next.issues.count - Self.issueLimit) }
    if failed, needsDecision == nil { next.status = .failed(message) }
    state = next  // 问题与状态一次送达
  }

  private func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }
}

extension SyncStatus {
  /// 一次成功的上传就能清掉的状态。
  fileprivate var isSettledFailure: Bool {
    switch self {
    case .failed, .quotaExceeded: true
    default: false
    }
  }
}

/// 停下来等你决定：这一页不应用，令牌不前移。
struct SyncPaused: Error {}

extension SendOutcome {
  /// 这条被拒的原因是可重试的（限流、服务忙等）：记下要等，取服务器给的最长等待。
  fileprivate mutating func wait(for error: CKError) {
    guard RecordSender.retryable.contains(error.code) else { return }
    let given = error.retryAfterSeconds.map { Duration.seconds($0) }
    switch throttled {
    case nil: throttled = .some(given)
    case .some(let current): throttled = .some([current, given].compactMap { $0 }.max())
    }
  }
}
