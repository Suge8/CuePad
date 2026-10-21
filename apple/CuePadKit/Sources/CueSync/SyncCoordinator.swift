import CloudKit
import Foundation
import os

/// 同步逻辑：远端变更应用、上传批次与结果处理、账号与状态。不碰网络：拉取器（`ZonePuller.pulled`）、发送者（`sent`、`nextBatch`）
/// 与账号检查（`CloudSync`）把服务器给的直接交进来。待推送只有库里推导的一份（`CueStore.pendingSync`）。
actor SyncCoordinator {
  static let issueLimit = 50
  static let log = Logger(subsystem: "com.sugeh.cuepad", category: "delivery")
  static let accountKey = "account"

  let store: CueStore
  nonisolated let zoneID: CKRecordZone.ID
  private var subscribers: [UUID: AsyncStream<SyncState>.Continuation] = [:]
  /// 构造不出来的记录（附件文件不在本机）与当时的修改时间：同一版不再每批重试、重复报告，改过再试。
  private var unsendable: [String: Int64] = [:]
  /// 库里没有可传的待推送，截至推导时的同步变更代数（`CueStore.pendingSync(since:)`）：之后只复查其后的提交碰过的记录，不再全量推导，
  /// 代数没变（按节奏的拉取每次顺带的那一轮）就什么都不查。`sending` 是在路上的这一批带走了推导出的全部、这批的条数：整批收下才算没有了（`processSent`）。
  var drained: (generation: Int, sending: Int?)?

  /// 协调器自己记的事实。`status` 不含 `.syncing`；上传与拉积压的忙闲分开记。对外的快照只在发布处推出（`state`）。
  struct Facts {
    var status = SyncStatus.starting
    var sending = false
    var catchingUp = false
    /// 库里有同步区令牌（`token()`、`setToken` 读写时记下）
    var reconciled = false
    var issues: [SyncIssue] = []
    var alerts = PiAlertSubscriptionStatus.off

    /// 界面看到的快照："同步中"是底层空闲、而一轮上传或拉积压正在进行。
    var state: SyncState {
      SyncState(
        status: status == .idle && (sending || catchingUp) ? .syncing : status, issues: issues, alerts: alerts, catchingUp: catchingUp,
        reconciled: reconciled)
    }
  }

  var facts = Facts() {
    didSet {
      let state = facts.state
      if state != oldValue.state { for continuation in subscribers.values { continuation.yield(state) } }
    }
  }

  var state: SyncState { facts.state }
  var status: SyncStatus { facts.status }
  var issues: [SyncIssue] { facts.issues }

  init(store: CueStore, zoneID: CKRecordZone.ID) {
    self.store = store
    self.zoneID = zoneID
  }

  // MARK: 状态订阅

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

  /// 能不能和服务器同步：有可用的账号，也没有停下（`stopped`）。
  var canSync: Bool {
    !stopped && ![.noAccount, .accountRestricted].contains(status)
  }

  /// 停下了：等你决定，或这台要更新（`SyncStatus.outdated`）。停下时不拉、不传，账号、同步区与上传失败都不改状态。
  var stopped: Bool { needsDecision != nil || status == .outdated }

  var alertSubscription: PiAlertSubscriptionStatus { facts.alerts }
  func setAlerts(_ alerts: PiAlertSubscriptionStatus) { facts.alerts = alerts }

  /// 用户对 `needsDecision` 的选择。之后重新开始同步（元数据、令牌与账号这里已清掉）。没有等你决定的事什么都不做：免得误擦数据。
  func resolve(_ resolution: SyncResolution) async throws {
    guard needsDecision != nil else { return }
    switch resolution {
    case .uploadLocal: try await store.resetSyncMetadata()
    case .eraseLocal: try await store.eraseSyncedData()
    }
    unsendable = [:]
    drained = nil
    facts.reconciled = false  // 两种处理都清掉了令牌
    facts.status = .idle
  }

  // MARK: 上传批次

  /// 下一批要上传的：`first` 里待推送的排在前面，至多 `limit` 条；没有可传的（或此刻不能同步）为 nil。
  /// 上次确定没有可传的之后只看其后的提交碰过的记录（`drained`）。
  func nextBatch(first: Set<String>, limit: Int) async -> (saves: [CKRecord], deletes: [CKRecord.ID])? {
    if drained?.sending != nil { drained = nil }  // 上一批整个没传成（没有结果）
    guard canSync else { return nil }
    let since = drained?.generation
    drained = nil
    let pending: PendingSync, generation: Int
    do { (pending, generation) = try await store.pendingSync(since: since) } catch {
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
    guard !batch.saves.isEmpty || !batch.deletes.isEmpty else {
      drained = (generation, nil)
      return nil
    }
    // 构造不出来的（附件文件不在本机）记进了 `unsendable`，同不可传的一样不算剩下
    if ordered.count == saves.count + ordered.count(where: { unsendable[$0] != nil }), batch.deletes.count == deletes.count {
      drained = (generation, saves.count + batch.deletes.count)
    }
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

  // MARK: 拉取器、发送者与账号检查交进来的

  func setSending(_ busy: Bool) { facts.sending = busy }

  /// 拉取器开始、结束拉积压（没有令牌时的对账，或一拉不止一页）。
  func setCatchingUp(_ busy: Bool) { facts.catchingUp = busy }

  /// 同步区令牌：只有库里一份（`ZonePuller.tokenKey`），读写都经这两处，顺带记下有没有（`SyncState.reconciled` 的唯一来源）。
  func token() async throws -> Data? {
    let token = try await store.syncState(ZonePuller.tokenKey)
    facts.reconciled = token != nil
    return token
  }

  func setToken(_ token: Data?) async throws {
    try await store.setSyncState(ZonePuller.tokenKey, token)
    facts.reconciled = token != nil
  }

  /// 同步开始时读一次令牌：还没拉过（离线、没登录）也说得出这台对没对过。
  func loadToken() async {
    do { _ = try await token() } catch { report(error, recordName: nil) }
  }

  /// 拉取器拉到的一页：应用完才返回；整页没能应用（库写不进去、停下了）时抛出，拉取器不前移令牌。
  /// 单条记录不合法只报告（见 `ZonePuller`）。页里的门槛高于这台的，整页不应用，更新后从这页接着拉。
  func pulled(_ modifications: [CKRecord], _ deletions: [(id: CKRecord.ID, recordType: String)]) async throws {
    guard !stopped else { throw SyncPaused() }
    try meet(modifications)
    guard !modifications.isEmpty || !deletions.isEmpty else { return }
    do {
      try await applyFetched(modifications, deletions)
    } catch {
      report(error, recordName: nil)
      throw error
    }
    if case .failed = status { facts.status = .idle }
    reached(nil)
  }

  /// 云端的最低对端版本（`PeerFloor`）高于这台能同步的结构版本：停下，抛出 `SyncPaused`。
  func meet(_ records: [CKRecord]) throws {
    guard let floor = PeerFloor.version(in: records), floor > CueStore.supportedSchemaVersions.upperBound else { return }
    facts.status = .outdated
    throw SyncPaused()
  }

  /// 上传结果：记账，并告诉发送者这批有没有进展、要不要停下来等。
  func sent(_ sent: SentRecords) async -> SendOutcome {
    guard !stopped else { return SendOutcome(progressed: false, blocked: true, zoneMissing: false) }
    reached(nil)
    do {
      return try await processSent(sent)
    } catch {
      report(error, recordName: nil)
      return SendOutcome(progressed: false, blocked: true, zoneMissing: false)
    }
  }

  var needsDecision: SyncDecision? {
    if case .needsDecision(let decision) = status { decision } else { nil }
  }

  func accountStatus(_ account: CKAccountStatus) {
    guard !stopped else { return }
    switch account {
    case .available:
      if [.starting, .noAccount, .accountRestricted, .accountUnavailable].contains(status) { facts.status = .idle }
    case .noAccount: facts.status = .noAccount
    case .restricted: facts.status = .accountRestricted
    case .temporarilyUnavailable, .couldNotDetermine: facts.status = .accountUnavailable
    @unknown default: facts.status = .accountUnavailable
    }
  }

  /// 此刻登录的 iCloud 账号（用户记录名）。第一次同步记下；和上次同步的不是同一个时，本机数据属于上一个账号，停下来等你决定。
  func account(_ name: String) async {
    guard !stopped else { return }
    let current = Data(name.utf8)
    do {
      guard let last = try await store.syncState(Self.accountKey) else { return try await store.setSyncState(Self.accountKey, current) }
      if last != current { facts.status = .needsDecision(.accountSwitched) }
    } catch {
      report(error, recordName: nil)
    }
  }

  /// 同步区不在了（`deletedByUser`：你在 iCloud 设置里删了 CuePad 的数据）：同步过的（有令牌或推送过的记录）是云端数据被删除或重置，
  /// 停下来等你决定；从没同步过的不用管，第一次上传时建区。
  func zoneMissing(deletedByUser: Bool) async {
    guard !stopped else { return }
    do {
      let hadToken = try await token() != nil
      let pushedAny = try await !store.syncedRecords().isEmpty
      let synced = hadToken || pushedAny
      try await setToken(nil)
      if synced { facts.status = .needsDecision(deletedByUser ? .cloudDataDeleted : .cloudDataReset) }
    } catch {
      report(error, recordName: nil)
    }
  }

  func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }
}

/// 停下了（等你决定，或这台要更新）：这一页不应用，令牌不前移。
struct SyncPaused: Error {}
