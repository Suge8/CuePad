import CueText
import Foundation

/// 某时刻之后，有会话的事或不归没做完的事的会话里的一处变化。
public struct CueChange: Equatable, Sendable {
  public enum Kind: String, Codable, Sendable, CaseIterable {
    /// 会话停下：这一轮做完歇下，或做到一半被打断（`interrupted`，会话状态是 `PiWorkState.interrupted`）
    case settled
    case waitingForUser
    /// 会话出错，或 Cue 发起的请求（开工、停下、结束、换模型）没能执行（`detail` 是"动作：Mac 报的原因"；你发起的失败界面上看得见，不报）
    case failed
    /// Cue 说的话（说话、作答，`DeliveryMode.toSession`）没送到，而它还不知道：工具等结果超时、收到报告的那一轮半路断了都算；
    /// 记下已知道的（`CueStore.markCueTold`）不再报（`detail` 是 Mac 报的原因）。会话那边在等它接着说，所以与等回答一样立即叫醒它
    case undelivered
    /// 叶子或任务完成
    case done
    /// 会话在等子代理，在跑的子代理都 `PiSessionState.stallAfter` 没有进展（`PiSessionState.stallsAt` 到了）：多半卡住了。
    /// 这不是一次写入，是时间到了：同一段停滞只报一次（`CueMarks.stalls`），有了新进展再停住是新的一段
    case stalled
  }

  public var kind: Kind
  /// 顶层任务；不归没做完的事的会话的变化为 nil。
  public var task: Card?
  /// 变化所在的叶子；任务本身的变化为 nil。
  public var leaf: Card?
  /// 变化所在的会话；任务完成这类不在会话上的变化为 nil。
  public var session: PiSessionState?
  /// 这一轮是他的（`CueStore.hisTurn`，由事实推出，不另存）：Cue 说的不算；扩展投进来的机器消息开的轮跟着它之前那句。
  public var byUser = false
  /// 事件发生的时刻（给 Cue 看）；分新旧看 `seq`
  public var at: Date
  /// 本机收到它的写入序号（`CueStore.lastWrite`）：越大越晚写进库
  public var seq: Int
  /// 提问、错误、哪个请求为什么没成。
  public var detail: String?
  /// 会话记录里已有的摘要：叶子的会话的；任务本身的变化取它最近有动静的那个会话的。
  public var recap: PiRecap?
  /// 停下是因为做到一半被打断（`PiWorkState.interrupted`），不是做完了。
  public var interrupted = false
}

extension PiSessionState {
  /// 停在要人接手的地方：歇下（最后一轮的回答已读到，`answered`，同它作为变化的时机）、在等回答或出错；被打断的不算，Cue 让它接着做。
  /// 谁接手（`CueStore.cueChanges`、`leaveHisStops`）只管这几种。等子代理停住时会话还在做，与完成、发送失败一样总报给 Cue。
  var atStop: Bool {
    switch state.known {
    case .settled: answered
    case .waitingForUser, .error: true
    default: false
    }
  }
}

/// 会话停下时他在不在场：正开着这个会话（某台设备的 `Viewer`），或 `window` 内在里面说过话（在终端里打的与在 CuePad 里发的一样，
/// Cue 发进去的不算）。他发起的一轮停下时他在场，先不报给 Cue，等他离开（`CueStore.cueChanges`）。由事实现推，不另存。
public struct SessionPresence: Equatable, Sendable {
  var viewing: Bool
  /// 窗口内最近一次在里面说话的时刻；窗口内没说过为 nil
  var spokeAt: Date?

  /// 10 分钟：比读完一段回复、想一想再回的时间长，比 Agent 一轮常见的十几分钟短——他说完走开，这一轮做完时多半已经不算在场；
  /// 与常见即时通讯"多久没动静算离开"同一个量级。
  /// 也是 Mac 上多久没动键盘鼠标就算人走开了（`ViewerKeeper`）：在场只有这一个口径。
  public static let window: TimeInterval = 10 * 60

  /// 没有新的动静就在这一刻算离开：只有说过话的那一半会到点；开着的那一半由设备写下离开（`Viewer`），不到点。
  var lapse: Date? { viewing ? nil : spokeAt.map { $0 + Self.window } }
}

/// 该报给 Cue 的变化，与他在场、等他离开再报的停下（`CueStore.cueChanges`）。
public struct CueChanges: Equatable, Sendable {
  /// 报给 Cue 的，按事件时刻从早到晚
  public var due: [CueChange]
  /// 他在场的停下：会话 id → 那次停下的起点。值班的管理器记着，下次对账交回来
  public var held: [String: Date]
  /// 这些停下里最早会到点的离开时刻（只有说过话的那一半会到点；开着的那一半由设备写下离开，管理器的订阅就醒）
  public var lapse: Date?
}

/// Cue 的变化从哪算起（本机写入序号，`CueStore.lastWrite`）：会话的动静从 `sessions` 之后，任务完成从 `tasks` 之后。
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

extension PiSessionState {
  /// 等子代理多久没进展算停住（`stallsAt`）：只此一处。
  public static let stallAfter: TimeInterval = 20 * 60

  /// 等子代理停住的时刻：在等子代理、在跑的子代理里最后一次进展（`PiSubagentState.progressAt`）之后 `stallAfter`。
  /// 不在等子代理、没有在跑的子代理（只剩 Claude Code 的后台命令，它不报进展），或有在跑的不知道进展时刻，为 nil。
  public var stallsAt: Date? {
    guard state == .known(.delegating) else { return nil }
    let progress = subagents.filter(\.isRunning).map(\.progressAt)
    guard !progress.isEmpty, !progress.contains(nil) else { return nil }
    return progress.compactMap { $0 }.max()! + Self.stallAfter
  }
}
