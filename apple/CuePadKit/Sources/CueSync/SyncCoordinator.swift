import CloudKit
import CueStore
import Foundation
import os

/// 同步逻辑：远端变更应用、上传批次与结果处理、账号与状态。不碰网络：拉取器（`ZonePuller.pulled`）、发送者（`sent`、`nextBatch`）
/// 与账号检查（`CloudSync`）把服务器给的直接交进来。待推送只有库里推导的一份（`CueStore.pendingSync`）。
/// 失败（服务器的与本机读写的）只经 `failed` 按 `SyncFault` 改状态、记问题；任何一次请求成功经 `succeeded` 收掉离线、同步出错与请求类的问题，并告诉发送者网络通了（`connectivity`）。
actor SyncCoordinator {
  static let issueLimit = 50
  static let log = Logger(subsystem: AppIdentity.id, category: "delivery")
  static let accountKey = "account"

  let store: CueStore
  nonisolated let zoneID: CKRecordZone.ID
  private let states = Broadcast(latest: Facts().state)
  /// 服务器收下了本机的一批改动（`CloudSync.acceptedUpdates`）。
  nonisolated let acceptances = Broadcast<Void>()
  /// 任何一次请求成功（连通的证据）：发送者因连不上在退避时据此当场再发（`RecordSender`）。
  nonisolated let connectivity = Broadcast<Void>(bufferingPolicy: .bufferingNewest(1))
  /// 这一版传不上去的记录与它的修改时间（删除记 `.min`）：附件文件不在本机、服务器拒收（`SyncFault.rejected`）。
  /// 同一版不再每批重试、重复报告，也不挡别的记录；改过再试，重启 App 也再试一次。
  var unsendable: [String: Int64] = [:]
  /// 库里没有可传的待推送，截至推导时的同步变更代数（`CueStore.pendingSync(since:)`）：之后只复查其后的提交碰过的记录，不再全量推导，
  /// 代数没变（按节奏的拉取每次顺带的那一轮）就什么都不查。只有后台那一路（`BatchScope.pending`）读写它，同一时刻至多一批：
  /// 交出带走了全部的一批时记在批上（`OutgoingBatch.drains`），整批收下才记回这里（`processSent`）。
  var drained: Int?

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
      if state != oldValue.state { states.yield(state) }
    }
  }

  var state: SyncState { facts.state }
  var status: SyncStatus { facts.status }
  var issues: [SyncIssue] { facts.issues }

  init(store: CueStore, zoneID: CKRecordZone.ID) {
    self.store = store
    self.zoneID = zoneID
  }

  // MARK: 订阅

  /// 先给出当前快照，之后每次变化给出新快照。
  nonisolated var stateUpdates: AsyncStream<SyncState> { states.stream() }

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
    facts.status = .starting
  }

  // MARK: 拉取器、发送者与账号检查交进来的

  /// 发送者有一批在路上，或因服务器要求等着重发：界面显示同步中。
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
    do { _ = try await token() } catch { failed(error) }
  }

  /// 拉取器拉到的一页：应用完才返回；整页没能应用（库写不进去、停下了）时抛出，拉取器不前移令牌。
  /// 单条记录不合法只报告（见 `ZonePuller`）。页里的门槛高于这台的，整页不应用，更新后从这页接着拉。
  func pulled(_ modifications: [CKRecord], _ deletions: [(id: CKRecord.ID, recordType: String)]) async throws {
    guard !stopped else { throw SyncPaused() }
    try meet(modifications)
    guard !modifications.isEmpty || !deletions.isEmpty else { return }
    try await applyFetched(modifications, deletions)  // 没应用成的由拉取器报（`failed`）
  }

  /// 云端的最低对端版本（`PeerFloor`）高于这台能同步的结构版本：停下，抛出 `SyncPaused`。
  func meet(_ records: [CKRecord]) throws {
    guard let floor = PeerFloor.version(in: records), floor > CueStore.supportedSchemaVersions.upperBound else { return }
    facts.status = .outdated
    throw SyncPaused()
  }

  var needsDecision: SyncDecision? {
    if case .needsDecision(let decision) = status { decision } else { nil }
  }

  /// 认到的账号状态。可用时仍是正在连接，第一次请求成功（`succeeded`）才算已同步：认了账号不等于连得上、对过门槛。
  func accountStatus(_ account: CKAccountStatus) {
    guard !stopped else { return }
    switch account {
    case .available:
      if [.noAccount, .accountRestricted, .accountUnavailable].contains(status) { facts.status = .starting }
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
      failed(error)
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
      failed(error)
    }
  }

  // MARK: 成功与失败

  /// 一次请求成功（拉完、收下了上传、对过门槛）：连上了。正在连接、连不上、账号暂不可用回到空闲，请求类的问题消失，没有失败类的问题了就不再是同步出错；
  /// 告诉发送者网络通了。停下时不改状态。
  func succeeded() {
    connectivity.yield(())
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

  /// 一次请求失败，按归类改状态（只在这里）：连不上显示离线、账号与配额写明、要等的不改、其余报告并显示同步出错。返回归类。
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
      report(SyncIssue.Problem(error), detail: error.diagnosis, kind: kind, recordType: recordType, recordName: recordName)
    }
    return fault
  }

  // MARK: 报告

  /// 记一条问题：同一类、同一条记录只留最新的一条（`SyncIssue.sameAs`）。失败类的让状态变成同步出错。
  /// 错误不直接报，经 `failed` 归类：连不上、要等、账号的不是问题。
  func report(_ problem: SyncIssue.Problem, detail: String? = nil, kind: SyncIssue.Kind, recordType: String?, recordName: String?) {
    var next = facts
    let issue = SyncIssue(kind: kind, recordType: recordType, recordName: recordName, problem: problem, detail: detail)
    next.issues.removeAll { $0.sameAs(issue) }
    next.issues.append(issue)
    if next.issues.count > Self.issueLimit { next.issues.removeFirst(next.issues.count - Self.issueLimit) }
    if issue.isFailure, !stopped { next.status = .failed }
    facts = next  // 问题与状态一次送达
  }

  func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }
}

/// 停下了（等你决定，或这台要更新）：这一页不应用，令牌不前移。
struct SyncPaused: Error {}
