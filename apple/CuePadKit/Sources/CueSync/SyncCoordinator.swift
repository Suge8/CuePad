import CloudKit
import CueStore
import Foundation
import os

/// 不碰网络：服务器给的由拉取器（`ZonePuller.pulled`）、发送者（`sent`、`nextBatch`）与账号检查（`CloudSync`）直接交进来。
/// 失败只经 `failed` 改状态、记问题，下次什么时候再发只经 `hold`（`SyncCoordinator+Hold`）；请求成功只经 `succeeded`。
actor SyncCoordinator {
  static let issueLimit = 50
  static let log = Logger(subsystem: AppIdentity.id, category: "delivery")
  static let syncLog = Logger(subsystem: AppIdentity.id, category: "sync")
  static let accountKey = "account"

  let store: CueStore
  nonisolated let zoneID: CKRecordZone.ID
  private let states = Broadcast(latest: Facts().state(accountUnconfirmed: false))
  private var published = Facts().state(accountUnconfirmed: false)
  /// 认清了没有不是这里的事实，这里只读（`CloudSync.start` 交进来）。
  private var gate = AccountGate()
  nonisolated let acceptances = Broadcast<Void>()
  /// 重试的等待结束了（到点、连通了、收下了一批）：发送者接着发，拉取器补上被挡下的那一拉（`SyncCoordinator+Hold`）。
  nonisolated let retryDue = Broadcast<Void>(bufferingPolicy: .bufferingNewest(1))
  var backoff = Backoff()
  var retryTimer: Task<Void, Never>?
  var outage: (fault: SyncFault, began: ContinuousClock.Instant)?
  /// 这一版传不上去的记录与它的修改时间（删除记 `.min`）：附件文件不在本机、服务器拒收（`SyncFault.rejected`）。
  /// 同一版不再每批重试、重复报告，也不挡别的记录；改过再试，重启 App 也再试一次。
  var unsendable: [String: Int64] = [:]
  /// 库里没有可传的待推送，截至推导时的同步变更代数（`CueStore.pendingSync(since:)`）：之后只复查其后的提交碰过的记录，不再全量推导，
  /// 代数没变（按节奏的拉取每次顺带的那一轮）就什么都不查。只有后台那一路（`BatchScope.pending`）读写它，同一时刻至多一批：
  /// 交出带走了全部的一批时记在批上（`OutgoingBatch.drains`），整批收下才记回这里（`processSent`）。
  var drained: Int?
  /// 文件那一路在传的附件记录（`takeFile`）：后台那一路不删它们，文件那一路不再交出（停下又开始同步时，上一轮的还在系统里传）。
  var fileUploads: Set<String> = []
  var quotaTimer: Task<Void, Never>?

  /// `status` 不含 `.syncing`；对外的快照只在发布处推出（`state`）。
  struct Facts {
    var status = SyncStatus.starting
    var sending = false
    var catchingUp = false
    /// 服务器要求的等待（`Hold.server`）在界面上算同步中，只从这里读。
    var holding: Hold?
    var reconciled = false
    var issues: [SyncIssue] = []
    var alerts = AlertSubscriptionStatus.off
    /// 之后传上去一个才清掉；别的记录照常同步，所以不进 `status`。
    var filesHeldUntil: ContinuousClock.Instant?

    func shown(accountUnconfirmed: Bool) -> SyncStatus {
      guard accountUnconfirmed else { return status }
      return switch status {
      case .needsDecision, .outdated, .noAccount, .accountRestricted: status
      default: .accountUnavailable
      }
    }

    func state(accountUnconfirmed: Bool) -> SyncState {
      let shown = shown(accountUnconfirmed: accountUnconfirmed)
      return SyncState(
        status: shown == .idle && (sending || catchingUp || holding?.server == true) ? .syncing : shown, issues: issues, alerts: alerts, catchingUp: catchingUp,
        reconciled: reconciled, filesOverQuota: filesHeldUntil != nil)
    }
  }

  var facts = Facts() {
    didSet { publish() }
  }

  var state: SyncState { facts.state(accountUnconfirmed: gate.current == .unconfirmed) }

  private func publish() {
    let state = state
    guard state != published else { return }
    published = state
    states.yield(state)
  }

  func use(_ gate: AccountGate) {
    self.gate = gate
    publish()
  }

  func gateChanged() { publish() }
  var status: SyncStatus { facts.status }
  var issues: [SyncIssue] { facts.issues }

  init(store: CueStore, zoneID: CKRecordZone.ID) {
    self.store = store
    self.zoneID = zoneID
  }

  /// 退避与空间不足的计时只弱持这里：同步整个没了（退出登录、换库、关掉 App 的服务）时，在等的计时不再攥着它与资料库直到到点。
  deinit {
    retryTimer?.cancel()
    quotaTimer?.cancel()
  }

  nonisolated var stateUpdates: AsyncStream<SyncState> { states.stream() }

  var canSync: Bool {
    !stopped && gate.current == .open && ![.noAccount, .accountRestricted].contains(status)
  }

  /// 停下时不拉、不传，账号、同步区与上传失败都不改状态。
  var stopped: Bool { needsDecision != nil || status == .outdated }

  var alertSubscription: AlertSubscriptionStatus { facts.alerts }
  func setAlerts(_ alerts: AlertSubscriptionStatus) { facts.alerts = alerts }

  /// 之后重新开始同步（元数据、令牌与账号这里已清掉）。没有等你决定的事什么都不做：免得误擦数据。
  func resolve(_ resolution: SyncResolution) async throws {
    guard needsDecision != nil else { return }
    switch resolution {
    case .uploadLocal: try await store.resetSyncMetadata()
    case .eraseLocal: try await store.eraseSyncedData()
    }
    unsendable = [:]
    drained = nil
    clearHolds()  // 上一个账号（或处理前）的退避、等待与空间不足不带进新的开始
    facts.reconciled = false  // 两种处理都清掉了令牌
    facts.status = .starting
  }

  func setSending(_ busy: Bool) { facts.sending = busy }

  func setCatchingUp(_ busy: Bool) { facts.catchingUp = busy }

  /// 令牌读写只经 `token()`、`setToken`，顺带记下有没有（`SyncState.reconciled` 的唯一来源）。
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
    do { _ = try await token() } catch { failed(error) }
  }

  /// 应用完才返回；整页没能应用（库写不进去、停下了）时抛出，拉取器不前移令牌。单条记录不合法只报告。
  func pulled(_ modifications: [CKRecord], _ deletions: [(id: CKRecord.ID, recordType: String)]) async throws {
    guard canSync else { throw SyncPaused() }
    try meet(modifications)
    guard !modifications.isEmpty || !deletions.isEmpty else { return }
    try await applyFetched(modifications, deletions)  // 没应用成的由拉取器报（`failed`）
  }

  func meet(_ records: [CKRecord]) throws {
    guard let floor = PeerFloor.version(in: records), floor > CueStore.supportedSchemaVersions.upperBound else { return }
    facts.status = .outdated
    throw SyncPaused()
  }

  var needsDecision: SyncDecision? {
    if case .needsDecision(let decision) = status { decision } else { nil }
  }

  /// 认到的账号状态。可用时仍是正在连接，第一次请求成功（`succeeded`）才算已同步：认了账号不等于连得上、对过门槛。
  /// 认账号的结论（这个、`account`、`accountFailed`）都要带那一次的凭据：不是最新在认的那次就不写（`AccountGate.Check`）。
  func accountStatus(_ account: CKAccountStatus, from check: AccountGate.Check) {
    guard !stopped, gate.admits(check) else { return }
    switch account {
    case .available:
      if [.noAccount, .accountRestricted, .accountUnavailable].contains(status) { facts.status = .starting }
    case .noAccount: facts.status = .noAccount
    case .restricted: facts.status = .accountRestricted
    case .temporarilyUnavailable, .couldNotDetermine: facts.status = .accountUnavailable
    @unknown default: facts.status = .accountUnavailable
    }
  }

  func account(_ name: String, from check: AccountGate.Check) async {
    guard !stopped, gate.admits(check) else { return }
    let gate = gate
    do {
      let match = try await store.matchAccount(Data(name.utf8), key: Self.accountKey) { gate.admits(check) }
      // 回到这里的途中又起了一次认：这次的结论已经过时（之后同步地写，新一次的写排在后面）
      guard match == .switched, !stopped, gate.admits(check) else { return }
      facts.status = .needsDecision(.accountSwitched)
    } catch {
      guard gate.admits(check) else { return }
      failed(error)
    }
  }

  func accountFailed(_ error: any Error, from check: AccountGate.Check) {
    guard gate.admits(check) else { return }
    if SyncFault(error).isOffline { failed(error) } else { accountStatus(.couldNotDetermine, from: check) }
  }

  func zoneMissing(deletedByUser: Bool) async {
    guard !stopped else { return }
    do {
      let hadToken = try await token() != nil
      let pushedAny = try await !store.syncedRecords().isEmpty
      let synced = hadToken || pushedAny
      try await setToken(nil)
      if synced { facts.status = .needsDecision(deletedByUser ? .cloudDataDeleted : .cloudDataReset) }
    } catch {
      failed(error)
    }
  }

  func succeeded() {
    connected()
    noteRecovered()
    guard !stopped else { return }
    var next = facts
    next.issues.removeAll { $0.kind == .request }
    switch next.status {
    case .starting, .offline, .accountUnavailable: next.status = .idle
    case .failed where !next.issues.contains(where: \.isFailure): next.status = .idle
    default: break
    }
    facts = next
  }

  /// 只在正常状态之间切换：要你决定、这台要更新这些更要紧的状态不被盖过。
  @discardableResult
  func failed(_ error: any Error, kind: SyncIssue.Kind = .request, recordType: String? = nil, recordName: String? = nil) -> SyncFault {
    let fault = SyncFault(error)
    guard !stopped else { return fault }
    switch fault {
    case .offline: if [.idle, .starting].contains(status) { facts.status = .offline }
    case .account(let status): facts.status = status
    case .wait: break
    case .rejected:
      report(SyncIssue.Problem(error), detail: error.diagnosis, kind: kind, recordType: recordType, recordName: recordName, reason: error.brief)
    }
    noteWaiting(fault, error)
    return fault
  }

  /// 错误不直接报，经 `failed` 归类：连不上、要等、账号的不是问题。日志只写 `reason`（见 `Error.brief`），没给时只记哪类问题、哪条记录：`detail` 可能带记录内容。
  func report(
    _ problem: SyncIssue.Problem, detail: String? = nil, kind: SyncIssue.Kind, recordType: String?, recordName: String?, reason: String? = nil
  ) {
    var next = facts
    let issue = SyncIssue(kind: kind, recordType: recordType, recordName: recordName, problem: problem, detail: detail)
    if !next.issues.contains(where: { $0.sameAs(issue) }) {
      Self.syncLog.error(
        "同步问题（\(String(describing: kind), privacy: .public)）：\(String(describing: problem), privacy: .public) \(recordType ?? "", privacy: .public) \(recordName?.prefix(8) ?? "", privacy: .public) \(reason ?? "", privacy: .public)")
    }
    next.issues.removeAll { $0.sameAs(issue) }
    next.issues.append(issue)
    if next.issues.count > Self.issueLimit { next.issues.removeFirst(next.issues.count - Self.issueLimit) }
    if issue.isFailure, !stopped { next.status = .failed }
    facts = next  // 问题与状态一次送达
  }

  func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }
}

struct SyncPaused: Error {}

enum AccountMatch { case recorded, same, switched }

extension CueStore {
  /// 比对并记下同步的账号，在资料库自己的队列上一步做完：读、比、写之间插不进别的读写（另一次认的比对排在前或后，不交错）。
  /// `latest` 不是 true（这一次已被更新的一次取代）就什么都不写，返回 nil。查过之后、写下之前另起的那次排在这次之后读，等同于这次更早写完；
  /// 不把判定和写入挪进闸门的锁里：那样起新的一次认要在锁里等资料库写入。
  fileprivate func matchAccount(_ current: Data, key: String, latest: @Sendable () -> Bool) throws -> AccountMatch? {
    guard latest() else { return nil }
    guard let last = try syncState(key) else {
      try setSyncState(key, current)
      return .recorded
    }
    return last == current ? .same : .switched
  }
}
