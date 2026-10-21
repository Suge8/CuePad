import CueText
import Foundation

/// Cue 此刻在做什么（同步，只有一行，只由它值班的那台 Mac 写）：与 Agent 会话同一套工作状态（`PiWorkState`）。
/// 一轮里是思考（`thinking`）或调用工具（`tool`，`detail` 是"动作 · 目标"，同会话的工具说明），一轮之间歇着（`settled`），
/// 大脑起不来是出错（`error`，`detail` 是原因）。别的设备与这台 Mac 的界面都只读它（`CuePresence`）。
public struct CueState: Equatable, Sendable {
  public var state: Open<PiWorkState>
  /// 正在跑的那一步（"动作 · 目标"，`CueActivity.detail`）
  public var detail: String?
  /// 在跑的这一轮的经过那一行（`CueStore.recordCueRound`）；还没调过工具、歇着时没有
  public var round: UUID?
  /// 它这个班次的上下文（`CueContext`），值班的 Mac 随状态写；不在值班、这个班次还没请求过模型为 nil
  public var context: CueContext?
  /// 它留给你回的会话（`CueLeft`，只由 `CueStore.leaveToYou` 写，`setCueState` 不动它）
  public var left: [CueLeft]
  public var modifiedAt: Date

  public init(
    state: Open<PiWorkState>, detail: String? = nil, round: UUID? = nil, context: CueContext? = nil, left: [CueLeft] = [], modifiedAt: Date = .now
  ) {
    self.left = left
    self.state = state
    self.detail = detail
    self.round = round
    self.context = context
    self.modifiedAt = modifiedAt
  }

  static let recordID = DeterministicID.uuid("cue-state")
}

/// Cue 此刻的上下文（一个班次一份）：用了多少 token、模型的窗口（大脑没报为 nil）、这个班次几点起。用到 `renewAt` 后，
/// 下一次醒来的信封要它先写交接备忘再换新（`CueEnvelope`）。随 `CueState` 同步，各端的上下文用量只读它。
public struct CueContext: StoredJSON, Equatable, Sendable {
  public var used: Int
  public var window: Int?
  public var since: Date

  public static let renewAt = 60_000

  /// token 数的写法（各端的上下文用量与 Mac 的运行情况同一种）：不到一千写原数，往上写 5.3k、128k。
  public static func tokens(_ count: Int) -> String {
    count >= 1000 ? "\((Double(count) / 1000).formatted(.number.precision(.fractionLength(0...1))))k" : "\(count)"
  }

  public init(used: Int, window: Int?, since: Date) {
    self.used = used
    self.window = window
    self.since = since
  }
}

/// Cue 这一轮为什么醒（值班的管理器起一轮时定下）。交给大脑的信封照它写"醒来："；Cue 自己醒来的一轮把它记在这一轮的经过那一行上
/// （`CueMessage.wake`，随那一行同步），Cue 页那一节的第一行照它写、点了去叫醒它的会话，叫醒的接力（`CueFlight`）也只读它。
public enum CueWake: StoredJSON, Equatable, Sendable {
  /// 刚启用：第一次醒来
  case enabled
  /// 你发来新消息
  case message
  /// 在做的事里有动静（`CueChange`）：哪几处，按事件时刻从早到晚
  case sessionActivity([CueStir])
  /// 空闲巡视
  case idle
  case tidy  // 合并记忆
  /// 提醒到点：到点的那几条记忆
  case reminder([UUID])
  /// 换了新上下文：接着做（交接在信封的"接上"里）
  case renewed
  /// 他改了要换大脑的设置（名字、Agent，或模型、强度回到默认）：先写交接
  case settingsChanged
}

/// 叫醒 Cue 的一处动静：`CueChange` 里界面要的那点——出了什么事、在哪个会话、哪件任务。
public struct CueStir: Codable, Equatable, Sendable {
  public var kind: CueChange.Kind
  /// Pi 的会话 id；任务完成这类不在会话上的为 nil
  public var session: String?
  /// 变化所在的那件（叶子，任务本身的变化是任务）
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

/// Cue 把会话的这一次停下留给你回（`CueStore.leaveToYou`）：会话停在 `since` 起的那次停下（歇着或等回答）时成立，
/// 谁再对它说话、它动起来（`stateSince` 变了）就自然作废，不用谁去清。只有一份：会话列表的"待回复"、等你确认与"等你 N"都经 `CueDuty` 读它。
public struct CueLeft: StoredJSON, Hashable, Sendable {
  public var sessionID: String
  public var since: Date

  public init(sessionID: String, since: Date) {
    self.sessionID = sessionID
    self.since = since
  }

  /// 这一条说的就是会话此刻的这次停下。
  public func holds(for session: PiSessionState) -> Bool {
    session.sessionID == sessionID && session.stateSince.stored == since.stored && session.state.known?.isStopped == true
  }
}

/// Cue 在值班时各端看会话要用的那一份（`CueStore.cueDuty`；不在值班为 nil）：它的名字（"等 X 回答"）与它留给你回的会话。
/// 会话等的是 Cue 还是你（`PiSessionState.waitsForCue`、`asksYou`）、会话行的"待回复"都只读它。
public struct CueDuty: Equatable, Sendable {
  public var name: String
  public var left: [CueLeft]

  public init(name: String, left: [CueLeft] = []) {
    self.name = name
    self.left = left
  }

  public func leftToYou(_ session: PiSessionState) -> Bool { left.contains { $0.holds(for: session) } }
}

extension CueState: Record {
  static let table = Table.cueState
  static let columns = ["id", "state", "detail", "modifiedAt", "round", "context", "leftToYou"]
  var bindings: [any SQLBindable] {
    [Self.recordID, state.rawValue, detail, modifiedAt, round, context?.stored, left.isEmpty ? nil : JSONColumn.encode(left)]
  }
  init(row: Row) {
    self.init(
      state: Open(rawValue: row.text(1)), detail: row.textOrNil(2), round: row.uuidOrNil(4), context: row.textOrNil(5).flatMap(CueContext.init(stored:)),
      left: JSONColumn.decodeList(CueLeft.self, from: row.textOrNil(6)), modifiedAt: row.date(3))
  }
}
