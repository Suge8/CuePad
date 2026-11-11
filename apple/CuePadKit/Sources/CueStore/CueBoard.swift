import Foundation

/// 界面（Mac 的“开始”、手机发给 Agent 的默认目标）与 Cue 的 `startLeaf` 共用这一份规则。
public struct HandOffPlan: Equatable, Sendable {
  public enum Destination: Equatable, Sendable {
    /// 执行的 Mac 是会话所在的那台；记录还没到时是发起的这台，手机上为 nil。
    case session(id: String, title: String, host: String?)
    /// 那台没绑文件夹时它先建工作区。
    case launch(project: UUID, host: String)
  }

  public var leaf: UUID
  public var destination: Destination
  public var opensSession: Bool { if case .session = destination { false } else { true } }
  public var name: String?
}

/// 在做的（`active`）归值班的 Cue 管，其余是你手上的清单。
public struct CueBoard: Equatable, Sendable {
  public var tasks: [CueBoardItem]
  public var sessions: [SessionState]

  /// 与执行集合分离，停机或离线不撤销进度。
  public var inProgress: [CueWork] { tasks.filter { $0.task.status == .inProgress }.map(CueWork.task) + sessions.map(CueWork.session) }

  /// 执行集合：信封与 peek 的“在做”；没有执行证据的静置任务不在内。值班管理器只问有没有时读 `CueStore.cueBoardActive`。
  public var active: [CueWork] { tasks.filter(\.isActive).map(CueWork.task) + sessions.map(CueWork.session) }
}

public enum CueWork: Identifiable, Equatable, Sendable {
  case task(CueBoardItem)
  case session(SessionState)

  public var id: String {
    switch self {
    case .task(let item): "task/\(item.id.uuidString)"
    case .session(let state): "session/\(state.sessionID)"
    }
  }

  public var task: Card? { if case .task(let item) = self { item.task } else { nil } }

  public var sessions: [SessionState] { CueAgents.sessions(in: [self]) }
}

public struct CueBoardItem: Identifiable, Equatable, Sendable {
  public var task: Card
  public var progress: TaskProgress?
  /// 至少一个：没有在做的就是此刻该做的那一个（无子任务是任务自己，否则第一个没完成的子任务）。
  /// 子任务都做完了时取最后做完的那一步（近况取它的会话，不落回第一步）。
  public var leaves: [CueBoardLeaf]
  public var id: UUID { task.id }
  public var isActive: Bool { leaves.contains(where: \.isActive) }
  public var session: SessionState? { leaves.lazy.compactMap(\.session).first }
  public var reaching: Bool { leaves.contains { $0.launching || $0.sending } }
}

public struct CueBoardLeaf: Equatable, Sendable {
  public var leaf: Card
  public var session: SessionState?
  /// 唯一占位入口 `handoffRequests` 的原记录；防重复，不代表此刻在跑。
  public let handoffs: [DeliveryRequest]
  private let activity: Set<DeliveryMode>
  public var launching: Bool { activity.contains(.start) }
  public var sending: Bool { activity.contains(.send) }

  init(leaf: Card, session: SessionState?, handoffs: [DeliveryRequest], since: Date, at moment: Speech.Moment) {
    self.leaf = leaf
    self.session = session
    self.handoffs = handoffs
    self.since = since
    activity = Set(handoffs.filter { Speech.activity($0, at: moment) != nil }.compactMap(\.mode.known))
  }
  public var since: Date

  public var isActive: Bool { launching || sending || session.map { $0.state != .known(.ended) } ?? false }
}

public struct CueTaskDetail: Equatable, Sendable {
  public var task: Card
  public var progress: TaskProgress?
  public var leaves: [CueLeafDetail]
}

public struct CueLeafDetail: Equatable, Sendable {
  public var leaf: Card
  public var session: CueSessionDetail?
  public var handoffs: [DeliveryRequest]
}

public struct CueSessionDetail: Equatable, Sendable {
  public var session: SessionState
  public var recent: [ChatMessage]
  public var cueSent: Set<UUID>
  /// 比 `recent` 更早、Cue 对这个会话说的话（开工那句与之后托付的），从早到晚：交回时逐件核对它们做到没有，
  /// 不另记"托付了什么"，会话里 Cue 说过的话就是那一份。
  public var earlier: [ChatMessage]
}
