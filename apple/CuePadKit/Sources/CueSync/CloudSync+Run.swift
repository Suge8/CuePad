import Foundation
import Synchronization

extension CloudSync {
  struct Run: Sendable {
    let generation: SyncGeneration
    let cloud: any SyncCloud
    let gate = AccountGate()
    var link = Link.unconfirmed
    var account = Account.idle
    var backoff = Backoff()
    var watchers: [Task<Void, Never>] = []
    var background: [UUID: Task<Void, Never>] = [:]
    var alertsAttemptedAt: ContinuousClock.Instant?

    init(generation: SyncGeneration, cloud: any SyncCloud) {
      self.generation = generation
      self.cloud = cloud
    }

    var tasks: [Task<Void, Never>] {
      guard case .waiting(.retry(_, let timer)) = account else { return watchers + Array(background.values) }
      return watchers + Array(background.values) + [timer]
    }

    var isConnected: Bool { if case .connected = link { true } else { false } }

    var checking: Task<Bool, Never>? { if case .checking(let task) = account { task } else { nil } }
  }

  enum Link: Sendable {
    case unconfirmed
    case connected(Parts)
  }

  struct Parts: Sendable {
    let puller: ZonePuller
    let sender: RecordSender
    let fileSender: FileSender
    let fileFetcher: FileFetcher
  }

  enum Account: Sendable {
    case idle
    case checking(Task<Bool, Never>)
    case waiting(Wait)
  }

  enum Wait: Sendable {
    case retry(at: ContinuousClock.Instant, Task<Void, Never>)
    case accountChange
    case paused
  }
}

final class AccountGate: Sendable {
  struct Check: Sendable {
    fileprivate let gate: AccountGate
    fileprivate let seq: Int
  }

  enum Verdict: Sendable {
    case open
    case checking
    case unconfirmed
  }

  private struct State {
    var verdict = Verdict.open
    var issued = 0
    var latest: Int?
  }

  private let state = Mutex(State())

  var current: Verdict { state.withLock { $0.verdict } }

  func begin(closing: Bool) -> Check {
    state.withLock { state in
      state.issued += 1
      state.latest = state.issued
      if closing, state.verdict == .open { state.verdict = .checking }
      return Check(gate: self, seq: state.issued)
    }
  }

  func admits(_ check: Check) -> Bool { check.gate === self && state.withLock { $0.latest == check.seq } }

  func end(_ check: Check, verdict: Verdict?) -> Bool {
    guard check.gate === self else { return false }
    return state.withLock { state in
      guard state.latest == check.seq else { return false }
      state.latest = nil
      if let verdict { state.verdict = verdict }
      return true
    }
  }
}
