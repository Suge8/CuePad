import CueText
import Foundation

/// Cue 此刻在做什么（同步，只有一行，只由它值班的那台 Mac 写）：与 Agent 会话同一套工作状态（`PiWorkState`）。
/// 一轮里是思考（`thinking`）或调用工具（`tool`：碰到任务与会话的一步是 `step`，其余是 `detail`），一轮之间歇着（`settled`），
/// 大脑起不来是出错（`error`，`detail` 是原因）。别的设备与这台 Mac 的界面都只读它（`CuePresence`）。
public struct CueState: Equatable, Sendable {
  public var state: Open<PiWorkState>
  /// 正在跑的那一步没碰任务与会话时的一句（"动作 · 目标"、看板、回想，`CueActivity.detail`）；出错时是原因
  public var detail: String?
  /// 正在跑的那一步碰到的那一处（类别与对象，与每一步记下的同一对，`CueActivity.step`）：各端按按钮动词表写成一句（`CueActivity.line`）
  public var step: CueActivity.Touch?
  /// 在跑的这一轮的经过那一行（`CueStore.recordCueRound`）；还没调过工具、歇着时没有
  public var round: UUID?
  /// 它这个班次的上下文（`CueContext`），值班的 Mac 随状态写；不在值班、这个班次还没请求过模型为 nil
  public var context: CueContext?
  /// 它留给你回的会话（`CueLeft`，只由 `CueStore.leaveToYou` 写，`setCueState` 不动它）
  public var left: [CueLeft]
  public var modifiedAt: Date

  public init(
    state: Open<PiWorkState>, detail: String? = nil, step: CueActivity.Touch? = nil, round: UUID? = nil, context: CueContext? = nil, left: [CueLeft] = [],
    modifiedAt: Date = .now
  ) {
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

/// Cue 此刻的上下文（一个会话一份）：用了多少 token。用到 `renewAt` 后，下一次醒来先开新会话（`CueKeeper`）。
/// 随 `CueState` 同步，各端的上下文那一行只读它。旧版本存过的模型窗口（`window`）读时略过。
public struct CueContext: StoredJSON, Equatable, Sendable {
  public var used: Int
  /// 这个会话几点起：界面不读，照写，旧版本解码要它。
  public var since: Date

  /// 换新线：10 万 token。按真实时间线每次醒来约涨 8k，10 万与 6 万每天的花费只差约 1%，换新却从每天约 13 次降到约 8 次：
  /// 换新只省后面几轮的缓存读，代价是重写视图并丢掉会话里原样的经过，线太低就换得太勤；再往上每次醒来读的上下文变长，花费又涨回去。
  /// 管理器经 `CueTiming.renewAt` 读它（评测可缩短），界面直接读它。
  public static let renewAt = 100_000

  /// token 数的写法（各端的上下文用量与 Mac 的运行情况同一种）：不到一千写原数，往上写 5.3k、128k。
  public static func tokens(_ count: Int) -> String {
    count >= 1000 ? "\((Double(count) / 1000).formatted(.number.precision(.fractionLength(0...1))))k" : "\(count)"
  }

  public init(used: Int, since: Date) {
    self.used = used
    self.since = since
  }
}

/// Cue 这一轮为什么醒（值班的管理器起一轮时定下）。交给大脑的信封照它写"醒来："；Cue 自己醒来的一轮把它记在这一轮的经过那一行上
/// （`CueMessage.wake`，随那一行同步），Cue 页那一节的第一行照它写、点了去叫醒它的会话，叫醒的接力（`CueFlight`）也只读它。
/// 旧版本存下的、已不再有的原因（换新、改了设置、整理记忆）读出为 nil，那一节照没有醒来原因的旧动态显示。
public enum CueWake: StoredJSON, Equatable, Sendable {
  /// 刚启用：第一次醒来
  case enabled
  /// 你发来新消息
  case message
  /// 在做的事里有动静（`CueChange`）：哪几处，按事件时刻从早到晚
  case sessionActivity([CueStir])
  /// 空闲巡视
  case idle
  /// 提醒到点：到点的那几条记忆
  case reminder([UUID])
}

/// 叫醒 Cue 的一处动静：`CueChange` 里界面要的那点——出了什么事、在哪个会话、哪件任务。那一处当时叫什么在这一行的 `CueMessage.places` 里（加密同步）。
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
/// 谁再对它说话、它动起来（`stateSince` 变了）就自然作废，不用谁去清。只有一份：待回复（`PiSessionState.awaitsReply`）与会话在问的归不归你（`waitsForCue`）都经 `CueDuty` 读它。
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
/// 会话等的是 Cue 还是你（`PiSessionState.waitsForCue`、`asksYou`）、待回复（`awaitsReply`）都只读它。
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
  static let columns = ["id", "state", "detail", "modifiedAt", "round", "context", "leftToYou", "step"]
  var bindings: [any SQLBindable] {
    [Self.recordID, state.rawValue, detail, modifiedAt, round, context?.stored, left.isEmpty ? nil : JSONColumn.encode(left), step.map(JSONColumn.encode)]
  }
  /// 解不出的 `step`（更新版本加的类别）读成 nil：那一句退回状态词，此刻的其余照读。
  init(row: Row) {
    self.init(
      state: Open(rawValue: row.text(1)), detail: row.textOrNil(2), step: JSONColumn.decode(CueActivity.Touch.self, from: row.textOrNil(7)),
      round: row.uuidOrNil(4), context: row.textOrNil(5).flatMap(CueContext.init(stored:)),
      left: JSONColumn.decodeList(CueLeft.self, from: row.textOrNil(6)), modifiedAt: row.date(3))
  }
}
