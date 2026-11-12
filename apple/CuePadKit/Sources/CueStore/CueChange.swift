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
  public var at: Date
  public var seq: Int
  public var detail: String?
  public var recap: Recap?
  public var interrupted = false
}

extension SessionState {
  /// 停下等人接手（`WorkState.isStopped`），歇着的要读到这一轮的回答（`answered`）。等子代理停住时会话还在做，不算。
  var atStop: Bool { runtimeState.known?.isStopped == true && (runtimeState != .known(.settled) || answered) }
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
