import CueText
import Foundation

public struct CueChange: Equatable, Sendable {
  public enum Kind: String, Codable, Sendable, CaseIterable {
    case settled
    case waitingForUser
    /// 你发起的失败界面上看得见，不报；`detail` 是“动作：Mac 报的原因”。
    case failed
    /// Cue 说的话（说话、作答，`DeliveryMode.toSession`）没送到，而它还不知道：工具等结果超时、收到报告的那一轮半路断了都算；
    /// 记下已知道的（`CueStore.markCueTold`）不再报（`detail` 是 Mac 报的原因）。会话那边在等它接着说，所以与等回答一样立即叫醒它
    case undelivered
    case done
    /// 会话在等子代理，在跑的子代理都 `SessionState.stallAfter` 没有进展（`SessionState.stallsAt` 到了）：多半卡住了。
    /// 这不是一次写入，是时间到了：同一段停滞只报一次（`CueMarks.stalls`），有了新进展再停住是新的一段；`seq` 是会话记录的，
    /// 会话别的写入也会让它变，判这一段是不是新的只看 `at`。Cue 此刻说不进去的（他发起的那一轮）不报
    case stalled
  }

  public var kind: Kind
  public var task: Card?
  public var leaf: Card?
  public var session: SessionState?
  /// 这一轮是他的（`CueStore.hisTurn`，由事实推出，不另存）：Cue 说的不算；扩展投进来的机器消息开的轮跟着它之前那句。
  public var byUser = false
  public var at: Date
  public var seq: Int
  public var detail: String?
  public var recap: Recap?
  public var interrupted = false
}

extension SessionState {
  /// 被打断的不算，Cue 让它接着做。等子代理停住时会话还在做，与完成、发送失败一样总报给 Cue。
  var atStop: Bool {
    switch runtimeState.known {
    case .settled: answered
    case .waitingForUser, .error: true
    default: false
    }
  }
}

/// Cue 发进去的话不算他说的。他发起的一轮停下时他在场，先不报给 Cue，等他离开（`CueStore.cueChanges`）。
public struct SessionPresence: Equatable, Sendable {
  var viewing: Bool
  var spokeAt: Date?

  /// 10 分钟：比读完一段回复、想一想再回的时间长，比 Agent 一轮常见的十几分钟短——他说完走开，这一轮做完时多半已经不算在场；
  /// 与常见即时通讯"多久没动静算离开"同一个量级。
  /// 也是 Mac 上多久没动键盘鼠标就算人走开了（`ViewerKeeper`）：在场只有这一个口径。
  public static let window: TimeInterval = 10 * 60

  /// 没有新的动静就在这一刻算离开：只有说过话的那一半会到点；开着的那一半由设备写下离开（`Viewer`），不到点。
  var lapse: Date? { viewing ? nil : spokeAt.map { $0 + Self.window } }
}

public struct CueChanges: Equatable, Sendable {
  public var due: [CueChange]
  /// 值班的管理器记着，下次对账交回来。
  public var held: [String: Date]
  /// 开着的那一半由设备写下离开，管理器的订阅就醒。
  public var lapse: Date?
}

/// 一轮做完时，会话的动静从醒来时读到的序号算起（这一轮里写进来的下次还在），完成从这一轮结束时算起（这一轮里多是 Cue 自己做完的）。
/// 等子代理停住（`CueChange.Kind.stalled`）不是写入，按时刻算：停住的时刻在 `stalls` 之后才报，一轮做完时前移到醒来的时刻。
public struct CueMarks: Codable, Equatable, Sendable {
  public var sessions: Int
  public var tasks: Int
  /// 已报过的停住到此为止；nil 是还没报过（此前的进度里没有它），已到的都报
  public var stalls: Date?

  public init(sessions: Int, tasks: Int, stalls: Date? = nil) {
    self.sessions = sessions
    self.tasks = tasks
    self.stalls = stalls
  }

  public init(_ both: Int, stalls: Date? = nil) { self.init(sessions: both, tasks: both, stalls: stalls) }
}

extension SessionState {
  public static let stallAfter: TimeInterval = 20 * 60

  /// 不在等子代理、没有在跑的子代理（只剩 Claude Code 的后台命令，它不报进展），或有在跑的不知道进展时刻，为 nil。
  public var stallsAt: Date? {
    guard runtimeState == .known(.delegating) else { return nil }
    let progress = subagents.filter(\.isRunning).map(\.progressAt)
    guard !progress.isEmpty, !progress.contains(nil) else { return nil }
    return progress.compactMap { $0 }.max()! + Self.stallAfter
  }
}
