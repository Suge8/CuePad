import Foundation
import Synchronization

/// 一代的全部状态：`start` 建、`stop` 整个摘下收尾。旧一代的任务只能按自己的 `generation` 改它（`update`），找不到新一代，
/// 所以旧一代晚到的写入（认账号的答复、再认的排期、后台任务的登记）在类型上写不进新一代。
extension CloudSync {
  struct Run: Sendable {
    let generation: SyncGeneration
    let cloud: any SyncCloud
    /// 协调器放行拉传时读的那一份（`AccountGate`），与 `account` 在同一步改。
    let gate = AccountGate()
    var link = Link.unconfirmed
    var account = Account.idle
    /// 本代认了几次：只有最新的那一次能写协调器、改连接（`isLatest`）。
    var checks = 0
    var backoff = Backoff()
    /// 账号变化、网络回来、重试的等待结束：本代一直跟着的。
    var watchers: [Task<Void, Never>] = []
    /// 本代起的其余后台任务（文件那一路的启动、建通知订阅、认好后的那一拉）：结束时自己从登记里去掉。
    var background: [UUID: Task<Void, Never>] = [:]
    /// 上一次建通知订阅的时刻：没建成时 `syncNow` 顺带重试，至多每 `alertRetryInterval` 一次（按节奏的拉取、门铃也走它，可能很密）。
    var alertsAttemptedAt: ContinuousClock.Instant?

    init(generation: SyncGeneration, cloud: any SyncCloud) {
      self.generation = generation
      self.cloud = cloud
    }

    /// `stop` 要取消并等的（在认的那一次另见 `checking`）：跟着的、后台的与等着再认的定时。
    var tasks: [Task<Void, Never>] {
      guard case .waiting(.retry(_, let timer)) = account else { return watchers + Array(background.values) }
      return watchers + Array(background.values) + [timer]
    }

    var checking: Task<Bool, Never>? { if case .checking(_, let task) = account { task } else { nil } }
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
    /// 没在认、也不用等：本代还没认过，或连上之后最近一次认清了。
    case idle
    /// 正在认本代第 `seq` 次。之后来的账号变化另起一次：这次的答复可能是变化之前的，作废。
    case checking(seq: Int, Task<Bool, Never>)
    /// 最近一次没认清，等 `Wait` 再认。
    case waiting(Wait)
  }

  /// 没认清时等什么再认。按节奏的拉取、门铃、立即同步都不触发再认：它们来得密，认的答复不会因此变。
  enum Wait: Sendable {
    /// 认不了（离线、暂不可用、无法确定、认不出的状态）：按退避到点再认；网络回来、回到前台提前。
    case retry(at: ContinuousClock.Instant, Task<Void, Never>)
    /// 没登录、受限：等账号变化或回到前台。
    case accountChange
    /// 认清了，但同步停着（要你决定、要更新）：处理决定时重开一代；账号变化照样再认。
    case paused
  }
}

/// 这一代此刻认清账号没有，协调器放行拉传与显示状态时读（`SyncCoordinator.canSync`、`state`）。由 `CloudSync` 在改 `Run.account`
/// 的同一步写：写在本 actor 里同步完成，先后就是改的先后，晚到的旧答复不会盖掉新的。协调器只拿着当前这一代的（`use`）。
final class AccountGate: Sendable {
  enum Verdict: Sendable {
    /// 没连上（拉传本来就还没开始），或连上之后最近一次认清了。
    case open
    /// 连上之后账号变了、正在认：不拉不传，界面照旧。
    case checking
    /// 连上之后最近一次没认清：不拉不传，界面显示账号暂不可用。
    case unconfirmed
  }

  private let verdict = Mutex(Verdict.open)

  var current: Verdict { verdict.withLock { $0 } }

  func set(_ next: Verdict) { verdict.withLock { $0 = next } }
}
