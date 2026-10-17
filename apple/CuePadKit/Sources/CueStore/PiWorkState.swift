import Foundation

/// Pi 会话的工作状态。工作中不调工具就是思考：正在出字（"输出中"）不是同步的状态，只是 Mac 上读正在说的话（`PiDraft`）的显示。
public enum PiWorkState: String, Sendable, CaseIterable {
  case thinking, tool, waitingForUser, settled, error
  /// 自己这轮已经歇下，还有子代理在跑：仍在处理
  case delegating
  /// 在压缩上下文（手动 /compact、上下文快满时自动、溢出后压缩再重试）：工作中的一档，Pi 忙着，停止会中止压缩
  case compacting
  /// 会话已结束（用户在 CuePad 里结束它、终端里的 Pi 退出、换了会话），以及本机会话文件索引里的历史会话：记录留着，会话文件被删时才删。
  /// 一句话没说过的会话（没留下会话文件）不进历史，CuePad 后台托管的会话闲置退出也不算结束（见 `PiStateRecorder.exited`）。
  case ended
  /// 做到一半被打断：手上还有活（在跑一轮、等你确认、子代理还在跑）时进程没了——崩溃、被杀、App 更新时让旧扩展的托管进程退出，
  /// 或 App 启动对账时发现它已经不在（`PiStateRecorder.exited`、`reset`）。与已结束一样只存在于记录里，会话再动起来时换成新状态；
  /// 发话照常（Mac 在后台把它恢复起来再送达）。不进历史，留在"现在"等人接着做。
  case interrupted
  /// 会话还在跑，但它加载的扩展协议与 Mac 上的 CuePad 不同：读不到状态、发不了命令。
  /// 会自己重载的扩展等空闲后换上新版本；更早的要在终端里 /reload。不是"已结束"，不进历史。
  case incompatible

  /// 粗状态（状态起点只在它变的时候前进）：工作中、等你确认、出错、空闲。
  public var phase: Int {
    if isWorking { return 0 }
    switch self {
    case .waitingForUser: return 1
    case .error: return 2
    default: return 3
    }
  }

  /// 正在干活（思考、调用工具、等子代理、压缩）。
  public var isWorking: Bool {
    switch self {
    case .thinking, .tool, .delegating, .compacting: true
    case .waitingForUser, .settled, .error, .ended, .interrupted, .incompatible: false
    }
  }

  /// Pi 自己正在跑一轮（含弹窗等你确认）：此时发消息只能马上说或等它做完再说。等子代理不算——指挥官这轮已经歇下，消息直接开始新的一轮。
  public var isTurnRunning: Bool {
    switch self {
    case .thinking, .tool, .waitingForUser, .compacting: true
    case .delegating, .settled, .error, .ended, .interrupted, .incompatible: false
    }
  }

  /// 还有事没做完：这一轮在跑、在等你确认、或子代理还在跑。后台托管的 Pi 据此判断不能当空闲收掉；
  /// 与 `isTurnRunning` 的差别只有等子代理（这时指挥官自己没在跑一轮，但托管的进程还有活）。
  public var hasPendingWork: Bool { isWorking || self == .waitingForUser }
}

extension PiWorkState {
  /// 还有事没做完的状态（`hasPendingWork`），SQL `IN (…)` 里的列表。
  static let pendingWorkSQL = sqlList(allCases.filter(\.hasPendingWork))
  /// 收尾了的状态（已结束、被打断），SQL `IN (…)` 里的列表。
  static let closedSQL = sqlList([ended, interrupted])
}

extension Open<PiWorkState> {
  /// 不认识的状态不算在干活。
  public var isWorking: Bool { known?.isWorking == true }
}

/// 需要推送到手机锁屏的事件。只在"进入等你确认"和"从工作中进入完成"的那一次写入上置位，其余写入为 nil，
/// 服务端订阅据此触发一次通知（同一状态下的重复写入不会再通知）。
public enum PiAlert: String, Sendable, CaseIterable {
  case waitingForUser, settled

  /// 要不要提示的唯一规则（Mac 置位通知标志、手机在前台读同步来的记录做 App 内提示都用它）：进入等你确认；从工作中进入完成。
  /// 首次看到的会话（没有上一个状态）不提示，重启或重新读取时不会把旧事件再提示一遍。
  /// 状态起点（`since`）退回到上一个状态之前是回落、不是新的转换：歇着时的手动压缩做完、失败或被停止，扩展让会话回到压缩前的状态与起点，
  /// 压完不是"做完了"。
  public static func entering(_ state: PiWorkState, since: Date, from previous: (state: PiWorkState, since: Date)?) -> PiAlert? {
    guard let previous, since >= previous.since else { return nil }
    if state == .waitingForUser, previous.state != .waitingForUser { return .waitingForUser }
    if state == .settled, previous.state.isWorking { return .settled }
    return nil
  }
}

extension PiAlert {
  /// 这次转换要不要提示你：做完了照常；进入等回答只在会话真在等你时（`PiSessionState.asksYou`）。
  public func reaches(_ state: PiSessionState, cueOnDuty: Bool) -> Bool { self != .waitingForUser || state.asksYou(cueOnDuty: cueOnDuty) }
}

extension PiSessionState {
  /// 相对上一次读到的版本，要提示你的转换（`alert(since:)` 里只留 `PiAlert.reaches` 的）。
  public func alert(since previous: PiSessionState?, cueOnDuty: Bool) -> PiAlert? {
    alert(since: previous).flatMap { $0.reaches(self, cueOnDuty: cueOnDuty) ? $0 : nil }
  }

  /// 相对上一次读到的版本（nil：第一次读到），这个版本是不是一次要提示的转换。手机读到的是同步合并后的版本：状态没变而
  /// 状态起点往后走了，说明中间又经过了一轮工作（没读到），按"刚从工作中来"算。
  public func alert(since previous: PiSessionState?) -> PiAlert? {
    guard let previous, let state = state.known else { return nil }
    let missedRound = previous.state.known == state && stateSince > previous.stateSince
    let before = missedRound ? .thinking : previous.state.known
    return PiAlert.entering(state, since: stateSince, from: before.map { ($0, previous.stateSince) })
  }
}

/// 会话的计时基准（扩展给出，原样写入）。
public struct PiTimes: Sendable, Equatable {
  /// 进入当前粗状态（工作中、等你确认、出错、空闲、已结束）的时间；细状态（思考、工具、等子代理）之间切换不变。
  public var stateSince: Date
  /// 这段连续处理开始的时间：离开空闲起，到彻底歇下为止，中间等你确认也不断；空闲、出错、已结束时为 nil。
  public var busySince: Date?

  public init(stateSince: Date, busySince: Date?) {
    self.stateSince = stateSince
    self.busySince = busySince
  }
}
