import CueText
import Foundation

/// 同步，只有一行，只由它值班的那台 Mac 写。报告保留原值，当前断言只读 `runtimeState`：报告所属宿主必须仍在值班、同 boot 且 lease 有效；旧报告、换宿主与历史元数据不能补签证明。
public struct CueState: Equatable, Sendable {
  public var state: Open<WorkState>
  public var hostID: String?
  public var bootID: String?
  /// 读时按所属宿主、boot 与 lease 推出，不落库或同步。
  public var runtimeUntil: Date?
  public var runtimeState: Open<WorkState> { runtimeUntil == nil ? .unknown("unconfirmed") : state }
  public var detail: String?
  public var step: CueActivity.Touch?
  public var round: UUID?
  public var context: CueContext?
  /// 留给你回的会话（`CueLeft`，只由 `CueStore.putLeft` 写，`setCueState` 不动它）
  public var left: [CueLeft]
  public var modifiedAt: Date

  public init(
    state: Open<WorkState>, detail: String? = nil, step: CueActivity.Touch? = nil, round: UUID? = nil, context: CueContext? = nil, left: [CueLeft] = [],
    modifiedAt: Date = .now, hostID: String? = nil, bootID: String? = nil, runtimeUntil: Date? = nil
  ) {
    self.hostID = hostID
    self.bootID = bootID
    self.runtimeUntil = runtimeUntil
    self.left = left
    self.state = state
    self.detail = detail
    self.step = step
    self.round = round
    self.context = context
    self.modifiedAt = modifiedAt
  }

  static let recordID = DeterministicID.uuid("cue-state")
}

/// 随 `CueState` 同步，各端的上下文那一行只读它。旧版本存过的模型窗口（`window`）与会话起点（`since`）读时略过。
public struct CueContext: StoredJSON, Equatable, Sendable {
  public var used: Int

  /// 换新线：换新只省后面几轮的缓存读，代价是重写视图、丢掉会话里原样的经过，线低换得太勤；线高每次醒来读的上下文变长，花费涨回去。
  /// 按真实时间线（每次醒来约涨 8k），10 万比 6 万每天花费只差约 1%，换新从每天约 13 次降到约 8 次。
  /// 管理器经 `CueTiming.renewAt` 读它（评测可缩短），界面直接读它。
  public static let renewAt = 100_000

  public static func tokens(_ count: Int) -> String {
    count >= 1000 ? "\((Double(count) / 1000).formatted(.number.precision(.fractionLength(0...1))))k" : "\(count)"
  }

  public init(used: Int) {
    self.used = used
  }
}

/// 值班的管理器起一轮时定下。Cue 自己醒来的一轮把它记在这一轮的经过那一行上（`CueMessage.wake`，随那一行同步），Cue 页、叫醒的接力（`CueFlight`）都只读它。
/// 旧版本存下的、已不再有的原因读出为 nil，那一节照没有醒来原因的旧动态显示。
public enum CueWake: StoredJSON, Equatable, Sendable {
  case enabled
  case message
  case sessionActivity([CueStir])
  case idle
  case schedule([CueFire])
}

/// 叫醒得比本该晚过 `lateAfter` 就是错过了、醒来才补上（Mac 睡着、App 没开）：只是一句事实，经过、信封与任务气泡都按这一轮开始的时刻与它算（`late`），不另存状态。
public struct CueFire: Codable, Equatable, Sendable {
  public var line: UUID
  public var due: Date

  public init(line: UUID, due: Date) {
    self.line = line
    self.due = due
  }

  public static func late(_ due: Date, at: Date) -> Bool { at.timeIntervalSince(due) > lateAfter }

  /// 晚这么久算错过：准点时只差对账的那一下，Cue 正忙一轮时也就等几分钟
  private static let lateAfter: TimeInterval = 10 * 60
}

public struct CueStir: Codable, Equatable, Sendable {
  public var kind: CueChange.Kind
  public var session: String?
  public var task: UUID?

  public init(kind: CueChange.Kind, session: String? = nil, task: UUID? = nil) {
    self.kind = kind
    self.session = session
    self.task = task
  }

  public init(_ change: CueChange) {
    self.init(kind: change.kind, session: change.session?.sessionID, task: (change.leaf ?? change.task)?.id)
  }
}

/// 会话停在 `since` 起的那次停下（歇着、等回答或出错）时成立，它动起来（`stateSince` 变了）就自然作废，不用谁去清；
/// 在那之前谁再对它说了话，待回复当场就不算（`CueStore.sessionsAwaitingReply`），不等 Mac 送到。
/// 只有一份：待回复（`SessionState.awaitsReply`）与会话在问的归不归你（`waitsForCue`）都经 `CueDuty` 读它。
public struct CueLeft: StoredJSON, Hashable, Sendable {
  public var sessionID: String
  public var since: Date

  public init(sessionID: String, since: Date) {
    self.sessionID = sessionID
    self.since = since
  }

  public func holds(for session: SessionState) -> Bool {
    session.sessionID == sessionID && session.stateSince.stored == since.stored && session.runtimeState.known?.isStopped == true
  }
}

public struct CueDuty: Equatable, Sendable {
  public var name: String
  public var left: [CueLeft]

  public init(name: String, left: [CueLeft] = []) {
    self.name = name
    self.left = left
  }

  public func leftToYou(_ session: SessionState) -> Bool { left.contains { $0.holds(for: session) } }
}

extension CueState: Record {
  static let table = Table.cueState
  static let columns = ["id", "state", "detail", "modifiedAt", "round", "context", "leftToYou", "step", "hostID", "bootID"]
  var bindings: [any SQLBindable] {
    [Self.recordID, state.rawValue, detail, modifiedAt, round, context?.stored, left.isEmpty ? nil : JSONColumn.encode(left), step.map(JSONColumn.encode), hostID, bootID]
  }
  /// 解不出的 `step`（更新版本加的类别）读成 nil：那一句退回状态词，此刻的其余照读。
  init(row: Row) {
    self.init(
      state: Open(rawValue: row.text(1)), detail: row.textOrNil(2), step: JSONColumn.decode(CueActivity.Touch.self, from: row.textOrNil(7)),
      round: row.uuidOrNil(4), context: row.textOrNil(5).flatMap(CueContext.init(stored:)),
      left: JSONColumn.decodeList(CueLeft.self, from: row.textOrNil(6)), modifiedAt: row.date(3), hostID: row.textOrNil(8), bootID: row.textOrNil(9))
  }
}
