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
  public var advancing: [CueWork] {
    let held = held
    let yours = Set(waiting.compactMap { if case .session(let state, _) = $0 { state.sessionID } else { nil } } + replies.map(\.session.sessionID))
    return works.filter {
      switch $0 {
      case .task(let item): !held.contains(item.id)
      case .session(let state): !yours.contains(state.sessionID)
      }
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
  public func cueTally() throws -> CueTally {
    let waiting = try cueWaiting()
    let replying = try sessionsAwaitingReply()
    let owners = try sessionOwners(replying.map(\.sessionID))
    return CueTally(
      works: try cueBoard().inProgress, waiting: waiting, replies: replying.map { CueTally.Reply(session: $0, task: owners[$0.sessionID]?.task.id) })
  }

  public func cueWaiting() throws -> [CueTally.Wait] {
    let messages = try cueMessagesWaitingForYou()
    let sessions = try sessionsAskingYou()
    let owners = try sessionOwners(sessions.map(\.sessionID))
    return try messages.map { CueTally.Wait.message($0, task: try $0.taskID.flatMap(topLevelTask)) }
      + sessions.map { CueTally.Wait.session($0, task: owners[$0.sessionID]?.task.id) }
  }

  private func topLevelTask(_ id: UUID) throws -> UUID? {
    guard var card = try card(id) else { return nil }
    while let parent = card.parentID, let above = try self.card(parent), above.deletedAt == nil { card = above }
    return card.id
  }

  /// 唯一的规则。等你的计数、报给 Cue 的变化、会话行与会话条写的名字、App 的改名都读它：没删除、没归档的任务，做完了的也算（它的问题没答就还是在等你）；绑着几件时归没做完的，再归最近开始的——做完的旧任务不抢正在用它的那件。
  public func sessionOwners(_ sessionIDs: [String]) throws -> [String: (task: Card, leaf: Card)] {
    guard !sessionIDs.isEmpty else { return [:] }
    let leaves = try select(
      Card.self, where: "piSessionID IN (SELECT value FROM json_each(?)) AND todoAt IS NOT NULL AND \(Self.cardActive)",
      [JSONColumn.encode(sessionIDs)], orderBy: "completedAt IS NULL DESC, startedAt DESC, id")
    var owners: [String: (task: Card, leaf: Card)] = [:]
    for leaf in leaves where owners[leaf.piSessionID!] == nil {
      guard let task = try find(Card.self, try topTask(of: leaf.id)) else { continue }
      owners[leaf.piSessionID!] = (task, leaf)
    }
    return owners
  }
}
