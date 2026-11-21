import CloudKit
import CueStore
import Foundation
import os

actor SyncCoordinator {
  static let issueLimit = 50
  static let log = Logger(subsystem: AppIdentity.id, category: "delivery")
  static let syncLog = Logger(subsystem: AppIdentity.id, category: "sync")
  static let accountKey = "account"

  let store: CueStore
  nonisolated let zoneID: CKRecordZone.ID
  private let states = Broadcast(latest: Facts().state(accountUnconfirmed: false))
  private var published = Facts().state(accountUnconfirmed: false)
  private var gate = AccountGate()
  nonisolated let acceptances = Broadcast<Void>()
  nonisolated let retryDue = Broadcast<Void>(bufferingPolicy: .bufferingNewest(1))
  var backoff = Backoff()
  var retryTimer: Task<Void, Never>?
  var outage: (fault: SyncFault, began: ContinuousClock.Instant)?
  var unsendable: [String: Int64] = [:]
  var drained: [Lane: Int] = [:]
  /// 文件那一路在传的附件记录（`takeFile`）：后台通道不删它们，文件那一路不再交出（停下又开始同步时，上一轮的还在系统里传）。
  var fileUploads: Set<String> = []
  var quotaTimer: Task<Void, Never>?

  struct Facts {
    var status = SyncStatus.starting
    var sending = false
    var catchingUp = false
    var holding: Hold?
    var reconciled = false
    var issues: [SyncIssue] = []
    var alerts = AlertSubscriptionStatus.off
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

  deinit {
    retryTimer?.cancel()
    quotaTimer?.cancel()
  }

  nonisolated var stateUpdates: AsyncStream<SyncState> { states.stream() }

  var canSync: Bool {
    !stopped && gate.current == .open && ![.noAccount, .accountRestricted].contains(status)
  }

  var stopped: Bool { needsDecision != nil || status == .outdated }

  var alertSubscription: AlertSubscriptionStatus { facts.alerts }
  func setAlerts(_ alerts: AlertSubscriptionStatus) { facts.alerts = alerts }

  func resolve(_ resolution: SyncResolution) async throws {
    guard needsDecision != nil else { return }
    switch resolution {
    case .uploadLocal: try await store.resetSyncMetadata()
    case .eraseLocal: try await store.eraseSyncedData()
    }
    unsendable = [:]
    drained = [:]
    clearHolds()
    facts.reconciled = false
    facts.status = .starting
  }

  func setSending(_ busy: Bool) { facts.sending = busy }

  func setCatchingUp(_ busy: Bool) { facts.catchingUp = busy }

  func token() async throws -> Data? {
    let token = try await store.syncState(ZonePuller.tokenKey)
    facts.reconciled = token != nil
    return token
  }

  func setToken(_ token: Data?) async throws {
    try await store.setSyncState(ZonePuller.tokenKey, token)
    facts.reconciled = token != nil
  }

  func loadToken() async {
    do { _ = try await token() } catch { failed(error) }
  }

  func pulled(_ modifications: [CKRecord], _ deletions: [(id: CKRecord.ID, recordType: String)]) async throws {
    guard canSync else { throw SyncPaused() }
    try meet(modifications)
    guard !modifications.isEmpty || !deletions.isEmpty else { return }
    try await applyFetched(modifications, deletions)
  }

  func meet(_ records: [CKRecord]) throws {
    guard let floor = PeerFloor.version(in: records), floor > CueStore.supportedSchemaVersions.upperBound else { return }
    facts.status = .outdated
    throw SyncPaused()
  }

  var needsDecision: SyncDecision? {
    if case .needsDecision(let decision) = status { decision } else { nil }
  }

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
    facts = next
  }

  func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }
}

struct SyncPaused: Error {}

enum AccountMatch { case recorded, same, switched }

extension CueStore {
  fileprivate func matchAccount(_ current: Data, key: String, latest: @Sendable () -> Bool) throws -> AccountMatch? {
    guard latest() else { return nil }
    guard let last = try syncState(key) else {
      try setSyncState(key, current)
      return .recorded
    }
    return last == current ? .same : .switched
  }
}
