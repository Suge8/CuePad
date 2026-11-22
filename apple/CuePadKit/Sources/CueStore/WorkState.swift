import Foundation

public enum WorkState: String, Sendable, CaseIterable {
  case thinking, tool, waitingForUser, settled, error
  case delegating
  /// 在压缩上下文（手动 /compact、上下文快满时自动、溢出后压缩再重试）：工作中的一档，Pi 忙着，停止会中止压缩
  case compacting
  case ended
  case interrupted

  public var phase: Int {
    if isWorking { return 0 }
    switch self {
    case .waitingForUser: return 1
    case .error: return 2
    default: return 3
    }
  }

  public var isWorking: Bool {
    switch self {
    case .thinking, .tool, .delegating, .compacting: true
    case .waitingForUser, .settled, .error, .ended, .interrupted: false
    }
  }

  public var isTurnRunning: Bool {
    switch self {
    case .thinking, .tool, .waitingForUser, .compacting: true
    case .delegating, .settled, .error, .ended, .interrupted: false
    }
  }

  public var hasPendingWork: Bool { isWorking || self == .waitingForUser }

  var isStopped: Bool { self == .settled || self == .waitingForUser || self == .error || self == .interrupted }
}

extension WorkState {
  static let pendingWorkSQL = sqlList(allCases.filter(\.hasPendingWork))
  static let closed: [WorkState] = [.ended, .interrupted]
  /// `column`（会话记录的 state 列）不是 `states` 里任何一个的 SQL 条件。写成这几个值隔开的几段范围而不是 `NOT IN`、`!=`：
  /// 后者用不上 (state, stateSince) 索引，库里的会话绝大多数已结束，会整表读一遍带问答长文的行（真实库四千多条、冷读 50～65ms，
  /// 有的就在主线程的首屏读里）；几段范围只走索引里不在其中的那几条。
  static func outsideSQL(_ states: [WorkState], column: String = "state") -> String {
    let values = states.map(\.rawValue).sorted()
    let between = zip(values, values.dropFirst()).map { "(\(column) > '\($0)' AND \(column) < '\($1)')" }
    return "(" + (["\(column) < '\(values[0])'"] + between + ["\(column) > '\(values[values.count - 1])'"]).joined(separator: " OR ") + ")"
  }
}

extension Open<WorkState> {
  public var isWorking: Bool { known?.isWorking == true }
}

public enum AlertKind: String, Sendable, CaseIterable {
  case waitingForUser, settled, awaitsReply

  public static func entering(_ state: WorkState, since: Date, from previous: (state: WorkState, since: Date)?) -> AlertKind? {
    guard let previous, since >= previous.since else { return nil }
    if state == .waitingForUser, previous.state != .waitingForUser { return .waitingForUser }
    if state == .settled, previous.state.isWorking { return .settled }
    return nil
  }
}

public enum AlertTone: String, Sendable {
  case ask, done

  public static let enabledKey = "sounds"
}

extension AlertKind {
  public var tone: AlertTone { self == .waitingForUser ? .ask : .done }
}

extension SessionState {
  public func alert(since previous: SessionState?) -> AlertKind? {
    guard let previous, let state = state.known else { return nil }
    let missedRound = previous.state.known == state && stateSince > previous.stateSince
    let before = missedRound ? .thinking : previous.state.known
    return AlertKind.entering(state, since: stateSince, from: before.map { ($0, previous.stateSince) })
  }

  public var leftAlert: AlertKind { state == .known(.waitingForUser) ? .waitingForUser : .awaitsReply }
}

public struct SessionTimes: Sendable, Equatable {
  public var stateSince: Date
  public var busySince: Date?

  public init(stateSince: Date, busySince: Date?) {
    self.stateSince = stateSince
    self.busySince = busySince
  }
}
