import Foundation
import Synchronization

/// 旧一代的任务只能按自己的 `generation` 改它（`update`），找不到新一代，所以旧一代晚到的写入（认账号的答复、再认的排期、后台任务的登记）在类型上写不进新一代。
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
    /// 上一次建通知订阅的时刻：没建成时 `syncNow` 顺带重试，至多每 `alertRetryInterval` 一次（按节奏的拉取、门铃也走它，可能很密）。
    var alertsAttemptedAt: ContinuousClock.Instant?

    init(generation: SyncGeneration, cloud: any SyncCloud) {
      self.generation = generation
      self.cloud = cloud
    }

    /// 不含在认的那一次（`checking`）。
    var tasks: [Task<Void, Never>] {
      guard case .waiting(.retry(_, let timer)) = account else { return watchers + Array(background.values) }
      return watchers + Array(background.values) + [timer]
    }

    var isConnected: Bool { if case .connected = link { true } else { false } }

    var checking: Task<Bool, Never>? { if case .checking(let task) = account { task } else { nil } }
  }

  /// 认过账号（可用、是上次同步的那个）才连上，拉取器、发送者与文件两路这时才建：认不了（离线、没登录）时不拉也不传，
  /// 本机的同步元数据可能属于上一个账号。连上之后再认不清由闸门挡住拉传（`AccountGate`），这里仍是连上：部件不重建。
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

  /// 认账号的进度：账号认清了没有只看这里（连上之后的闸门由它推出）。
  enum Account: Sendable {
    case idle
    /// 正在认（哪一次是最新的只看闸门，`AccountGate.Check`）。之后来的账号变化另起一次：这次的答复可能是变化之前的，作废。
    case checking(Task<Bool, Never>)
    case waiting(Wait)
  }

  /// 按节奏的拉取、门铃、立即同步都不触发再认：它们来得密，认的答复不会因此变。
  enum Wait: Sendable {
    case retry(at: ContinuousClock.Instant, Task<Void, Never>)
    case accountChange
    /// 认清了，但同步停着（要你决定、要更新）：处理决定时重开一代；账号变化照样再认。
    case paused
  }
}

/// 由 `CloudSync` 在改 `Run.account` 的同一步写，写在本 actor 里同步完成，先后就是改的先后，晚到的旧答复不会盖掉新的；协调器只拿着当前这一代的（`use`）。
///
/// 也是认账号结论的唯一入口：每一次认从这里领凭据（`begin`），协调器写账号的结论都要带上它，不是这扇门最新在认的那一次就不写（`admits`）。
/// 凭据只有这里造得出，旧一次、旧一代的晚到答复因此在任何一个 await 之后都写不进去，以后加的入口也绕不过。
final class AccountGate: Sendable {
  struct Check: Sendable {
    fileprivate let gate: AccountGate
    fileprivate let seq: Int
  }

  enum Verdict: Sendable {
    /// 没连上（拉传本来就还没开始），或连上之后最近一次认清了。
    case open
    /// 连上之后账号变了、正在认：不拉不传，界面照旧。
    case checking
    /// 连上之后最近一次没认清：不拉不传，界面显示账号暂不可用。
    case unconfirmed
  }

  private struct State {
    var verdict = Verdict.open
    var issued = 0
    var latest: Int?
  }

  private let state = Mutex(State())

  var current: Verdict { state.withLock { $0.verdict } }

  /// 起新的一次认，之前的作废。`closing`：连着的当场关闸门（已是认不清的照旧）。
  func begin(closing: Bool) -> Check {
    state.withLock { state in
      state.issued += 1
      state.latest = state.issued
      if closing, state.verdict == .open { state.verdict = .checking }
      return Check(gate: self, seq: state.issued)
    }
  }

  func admits(_ check: Check) -> Bool { check.gate === self && state.withLock { $0.latest == check.seq } }

  /// 最新的这一次认完：之后它的凭据作废；`verdict` 不是 nil 时改闸门。不是最新的返回 false、什么都不改。
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
