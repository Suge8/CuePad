import Foundation

/// 推进中与等你只在这里算：Cue 那一行、任务看板中间两列、小组件、实时活动与 Dock 角标读的同一份。等你是总称，分拍板（`waiting`）与待回复（`replies`）两种；“等你 N”数两种（App 里的 `CueNow.needsYou`），只说拍板的地方只数 `waiting`。
/// 拍板：Cue 带选项问你、还没结束的消息，加上会话里在等你回答的；待回复：Cue 留给你回、此刻歇着的会话，等得最久的在前。每件带上它落在哪件顶层任务上，没落在任务上的为 nil。同一件任务上 Cue 在问、它的会话也在问，算两件。
/// 推进中：已开始未完成的任务与单独活会话（`CueBoard.inProgress`），去掉被等你占着的。
/// 被等你占着的（`held`）：它的会话在问你或待回复的顶层任务。一件事只在一处：它只算等你，不论状态是待办、进行中还是做完——推进中在这里去掉它们；任务看板与实时活动按列分时也先看它（App 里的 `TaskBoard.Column.of`）。Cue 落在任务上的提问不占着它：那件事留在原处，提问只在 Cue 页答。会话结束、出错或离线不撤销任务进度。
public struct CueTally: Equatable, Sendable {
  public enum Wait: Identifiable, Equatable, Sendable {
    case message(CueMessage, task: UUID?)
    case session(SessionState, task: UUID?)

    public var id: String {
      switch self {
      case .message(let message, _): "message/\(message.id.uuidString)"
      case .session(let state, _): "session/\(state.sessionID)"
      }
    }

    public var task: UUID? {
      switch self {
      case .message(_, let task), .session(_, let task): task
      }
    }
  }

  public struct Reply: Identifiable, Equatable, Sendable {
    public var session: SessionState
    public var task: UUID?

    public init(session: SessionState, task: UUID?) {
      self.session = session
      self.task = task
    }

    public var id: String { "reply/\(session.sessionID)" }
  }

  /// 全部未完成工作；拍板与待回复是否占着它只从当前 waiting/replies 推出。
  public var works: [CueWork]
  public var advancing: [CueWork] { works.filter { held(of: $0) == 0 } }

  /// 占着这件的等你有几件（会话在问你的拍板、待回复）。
  public func held(of work: CueWork) -> Int {
    waiting.count { if case .session(let state, let task) = $0 { Self.holds(work, task: task, session: state.sessionID) } else { false } }
      + replies.count { Self.holds(work, task: $0.task, session: $0.session.sessionID) }
  }

  /// 一件等你（落在 `task` 上、由会话 `session` 发出）占着哪件事，唯一的规则：落在任务上的占那件顶层任务，会话本身是一件事的占那个会话。
  public static func holds(_ work: CueWork, task: UUID?, session: String) -> Bool {
    switch work {
    case .task(let item): item.id == task
    case .session(let state): state.sessionID == session
    }
  }
  public var waiting: [Wait]
  public var replies: [Reply]
  public var held: Set<UUID> {
    Set(waiting.compactMap { if case .session(_, let task) = $0 { task } else { nil } } + replies.compactMap(\.task))
  }

  public init(works: [CueWork], waiting: [Wait], replies: [Reply]) {
    self.works = works
    self.waiting = waiting
    self.replies = replies
  }

  public static let empty = CueTally(works: [], waiting: [], replies: [])
}

extension CueStore {
  /// 你已经叫它歇了（结束在路上）的无主会话不在你看的推进中，不等那台 Mac 做完（同等你，`notEnding`）：不然完成后把卡归档、删掉，
  /// 它在歇下之前又冒回推进中，像没歇成；没结束成（失败）的照常回来。只在这里筛，不进 `isLoose`：Cue 那边照旧管着它，
  /// 不然歇着这一段里它的变化先被筛掉、Cue 的基线又走过去了，没歇成之后再也报不出来。
  public func cueTally() throws -> CueTally {
    let waiting = try cueWaiting()
    let replying = try sessionsAwaitingReply()
    let owners = try sessionOwners(replying.map(\.sessionID))
    let board = try cueBoard()
    return CueTally(
      works: CueBoard(tasks: board.tasks, sessions: try notEnding(board.sessions)).inProgress, waiting: waiting, replies: replying.map { CueTally.Reply(session: $0, task: owners[$0.sessionID]?.task.id) })
  }

  public func cueWaiting() throws -> [CueTally.Wait] {
    let messages = try cueMessagesWaitingForYou()
    let sessions = try sessionsAskingYou()
    let owners = try sessionOwners(sessions.map(\.sessionID))
    return try messages.map { message in
      CueTally.Wait.message(message, task: try message.taskID.flatMap { try card($0) == nil ? nil : top(of: $0) })
    } + sessions.map { CueTally.Wait.session($0, task: owners[$0.sessionID]?.task.id) }
  }

  /// 会话的主人（`sessionOwnerRows`）与它那件事的顶层任务。等你的计数、报给 Cue 的变化、会话行与会话条写的名字、App 的改名都读它。
  public func sessionOwners(_ sessionIDs: [String]) throws -> [String: (task: Card, leaf: Card)] {
    guard !sessionIDs.isEmpty else { return [:] }
    let rows = try db.query(Self.sessionOwnerTops(where: "piSessionID IN (SELECT value FROM json_each(?1))"), [JSONColumn.encode(sessionIDs)]) { (session: $0.text(0), leaf: $0.uuid(1), task: $0.uuid(2)) }
    let cards = Dictionary(uniqueKeysWithValues: try select(
      Card.self, where: "id IN (SELECT value FROM json_each(?))", [Self.idList(rows.flatMap { [$0.leaf, $0.task] })]).map { ($0.id, $0) })
    return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
      guard let task = cards[row.task], let leaf = cards[row.leaf] else { return nil }
      return (row.session, (task: task, leaf: leaf))
    })
  }

  /// 会话的主人只有这一条规则，一行（会话, 叶子），作子查询用：看板上绑着它的任务里（`taskOnBoard`，做完的也算：它的问题没答就还是在等你），
  /// 没做完的在前，再按最近开始的——做完的旧任务不抢正在用它的那件。`condition` 是对卡片表的条件。
  static func sessionOwnerRows(where condition: String) -> String {
    """
    SELECT sessionID, leaf FROM (
      SELECT piSessionID AS sessionID, id AS leaf,
        ROW_NUMBER() OVER (PARTITION BY piSessionID ORDER BY completedAt IS NULL DESC, startedAt DESC, id) AS rank
      FROM cards WHERE piSessionID IS NOT NULL AND \(taskOnBoard()) AND (\(condition)))
    WHERE rank = 1
    """
  }

  /// 会话、它的主人（`sessionOwnerRows`）与主人那件事的顶层（`tops`），一行（sessionID, leaf, top），作子查询用：会话归哪件事只在这里拼。
  static func sessionOwnerTops(where condition: String) -> String {
    """
    WITH owner(sessionID, leaf) AS (\(sessionOwnerRows(where: condition)))
    SELECT o.sessionID, o.leaf, up.top FROM owner o JOIN (\(tops(of: "SELECT leaf FROM owner"))) up ON up.start = o.leaf
    """
  }
}
