import Foundation

/// 任务交到哪（`CueStore.handOffPlan`）：界面（Mac 的"开始"、手机发给 Agent 的默认目标）与 Cue 的 `startLeaf` 共用这一份规则。
public struct HandOffPlan: Equatable, Sendable {
  public enum Destination: Equatable, Sendable {
    /// 叶子绑着的会话：Pi 的会话 id、显示名、由哪台 Mac 执行（会话所在的那台；记录还没到时是发起的这台，手机上为 nil）。
    case session(id: String, title: String, host: String?)
    /// 在项目的文件夹开新会话，由 `CueStore.launchHost` 定的那台 Mac 执行（那台没绑文件夹时它先建工作区）。
    case launch(project: UUID, host: String)
  }

  /// 交给会话的叶子。
  public var leaf: UUID
  public var destination: Destination
  /// 要开新会话（不是接着用已有的）：开工的第一句据此带不带顶层任务作背景（`CueStore.opening`）。
  public var opensSession: Bool { if case .session = destination { false } else { true } }
  /// 从这件事开的会话叫什么（`CueStore.sessionName(forCard:)`，`requestLaunch` 起名用的同一条规则）：叶子的标题；没有标题为 nil。
  public var name: String?
}

/// 看板（`CueStore.cueBoard`）：没做完的事，加上不归没做完的事的活会话。在做的（`active`）归值班的 Cue 管，其余是你手上的清单。
public struct CueBoard: Equatable, Sendable {
  public var tasks: [CueBoardItem]
  /// 不归没做完的事的活会话（`CueStore.isLoose`：他直接开的、终端里的，和只有已完成的事绑着的），最近有动静的在前。
  public var sessions: [PiSessionState]

  /// 在做的：在做的事（`CueBoardItem.isActive`）按看板顺序，再是不归没做完的事的活会话。信封与 peek 的"在做"、推进中（`CueTally`）都是它；
  /// 会话都结束了、没人在做的事不在内，留在你手上的清单里。只问有没有时读 `CueStore.cueBoardActive`（同一条规则，不读整块看板）。
  public var active: [CueWork] { tasks.filter(\.isActive).map(CueWork.task) + sessions.map(CueWork.session) }
}

/// 在做的一件（`CueBoard.active`）：在做的事，或不归没做完的事的活会话。
public enum CueWork: Identifiable, Equatable, Sendable {
  case task(CueBoardItem)
  case session(PiSessionState)

  public var id: String {
    switch self {
    case .task(let item): "task/\(item.id.uuidString)"
    case .session(let state): "session/\(state.sessionID)"
    }
  }

  /// 在做的事的顶层任务；会话为 nil。
  public var task: Card? { if case .task(let item) = self { item.task } else { nil } }
}

/// 看板上的一件事：一个没做完的顶层任务。在做的（`isActive`）归值班的 Cue 管，其余是你手上的清单。
public struct CueBoardItem: Identifiable, Equatable, Sendable {
  public var task: Card
  /// 步骤完成了几个；没有步骤为 nil。
  public var progress: TaskProgress?
  /// 在做的叶子，至少一个（按步骤顺序）：没做完、开着会话（会话没结束，或做到一半被打断）、正在开会话或话正送进会话的每一个——
  /// 并行做的几步都在。一个都没有时是此刻该做的那一个：没有步骤是任务自己，否则第一个没完成的步骤；
  /// 步骤都做完了是最后做完的那一步（近况取它的会话，不落回第一步）。
  public var leaves: [CueBoardLeaf]
  public var id: UUID { task.id }
  public var isActive: Bool { leaves.contains(where: \.isActive) }
}

public struct CueBoardLeaf: Equatable, Sendable {
  public var leaf: Card
  /// 叶子的会话记录；还没开会话（或记录还没到）为 nil。
  public var session: PiSessionState?
  /// 正在为叶子开新会话（请求还没执行完，或开好了还没认领到）。
  public var launching: Bool
  /// 叶子还没绑会话、它的话正送进上一步的会话（`CueStore.sendingLeaves`；送到时绑上）。
  public var sending: Bool
  /// 停在当前状态的起点：会话进入当前状态的时刻，没有会话时是开始做或设为任务的时刻。
  public var since: Date

  /// 在做：会话没结束，或正在开会话、话正送进会话。
  public var isActive: Bool { launching || sending || session.map { $0.state != .known(.ended) } ?? false }
}

/// 一件事的细节（Cue 的 peek）：叶子与各自的会话。
public struct CueTaskDetail: Equatable, Sendable {
  public var task: Card
  public var progress: TaskProgress?
  public var leaves: [CueLeafDetail]
}

public struct CueLeafDetail: Equatable, Sendable {
  public var leaf: Card
  /// 叶子的会话；还没开会话（或记录还没到）为 nil。
  public var session: CueSessionDetail?
  /// 还没绑会话、话正送进上一步的会话（同 `CueBoardItem.sending`）。
  public var sending: Bool
}

/// 一个会话的细节（Cue 的 peek）：记录与最近几轮问答。
public struct CueSessionDetail: Equatable, Sendable {
  public var session: PiSessionState
  /// 最近几轮问答（会话里用户一方说的与 Agent 的回答），从早到晚。
  public var recent: [PiChatMessage]
  /// `recent` 里 Cue 说的那几条的请求 id（`cueSentDeliveries`，与会话页同一条规则，见 `PiChatMessage.saidByCue`）。
  public var cueSent: Set<UUID>
}
