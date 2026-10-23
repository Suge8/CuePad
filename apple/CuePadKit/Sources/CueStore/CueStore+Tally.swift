import Foundation

/// 推进中与等你：Cue 那一行、任务看板中间两列、小组件、实时活动与 Dock 角标读的同一份，只在这里算。
/// - 等你：Cue 带选项问你、还没结束的消息（`cueMessagesWaitingForYou`），加上会话里在等你回答的（`sessionsAskingYou`，规则在 `PiSessionState.asksYou`）。
///   一处在等就是一件：同一件任务上 Cue 在问、它的会话也在问，算两件。每件带上它落在哪件顶层任务上（消息的 `taskID`、会话归的那件 `sessionOwners`），没落在任务上的为 nil。
/// - 被等你占着的（`held`）：有一件等你落在它上面的顶层任务。一件事只在一处：它只算等你，不论状态是待办、进行中还是做完——
///   推进中、任务看板的待办与做完、实时活动的做完都先去掉它们（`free`）。
/// - 推进中：Cue 此刻在做的（`CueBoard.active`，即它信封里的"在做"）里不在等你的：被等你占着的事与在问你的会话去掉；先后同看板。
///   进行中而会话都结束了、没人在做的事不算，它留在你的任务清单里（任务看板的待办）。
public struct CueTally: Equatable, Sendable {
  public enum Wait: Identifiable, Equatable, Sendable {
    case message(CueMessage, task: UUID?)
    case session(PiSessionState, task: UUID?)

    public var id: String {
      switch self {
      case .message(let message, _): "message/\(message.id.uuidString)"
      case .session(let state, _): "session/\(state.sessionID)"
      }
    }

    /// 落在哪件顶层任务上。
    public var task: UUID? {
      switch self {
      case .message(_, let task), .session(_, let task): task
      }
    }
  }

  public var advancing: [CueWork]
  public var waiting: [Wait]

  public var held: Set<UUID> { Set(waiting.compactMap(\.task)) }

  /// 去掉被等你占着的（`held`）：推进中，与看板、实时活动按状态分的那几份都经它。
  public func free(_ tasks: [Card]) -> [Card] {
    let held = self.held
    return tasks.filter { !held.contains($0.id) }
  }

  public init(advancing: [CueWork], waiting: [Wait]) {
    self.advancing = advancing
    self.waiting = waiting
  }

  public static let empty = CueTally(advancing: [], waiting: [])
}

extension CueStore {
  public func cueTally() throws -> CueTally {
    let waiting = try cueWaiting()
    var tally = CueTally(advancing: [], waiting: waiting)
    let held = tally.held
    let asking = Set(waiting.compactMap { if case .session(let state, _) = $0 { state.sessionID } else { nil } })
    tally.advancing = try cueBoard().active.filter { work in
      switch work {
      case .task(let item): !held.contains(item.id)
      case .session(let state): !asking.contains(state.sessionID)
      }
    }
    return tally
  }

  /// 只有等你那一份（`CueTally.waiting`，同一条规则）：Cue 页的等你卡只读它，不连带推进中的那些读取。
  public func cueWaiting() throws -> [CueTally.Wait] {
    let messages = try cueMessagesWaitingForYou()
    let sessions = try sessionsAskingYou()
    let owners = try sessionOwners(sessions.map(\.sessionID))
    return try messages.map { CueTally.Wait.message($0, task: try $0.taskID.flatMap(topLevelTask)) }
      + sessions.map { CueTally.Wait.session($0, task: owners[$0.sessionID]?.task.id) }
  }

  /// 这件任务所在的顶层任务（上级不在库里或不可见时按顶层看待，同 `Card.parentID`）；任务不在库里为 nil。
  private func topLevelTask(_ id: UUID) throws -> UUID? {
    guard var card = try card(id) else { return nil }
    while let parent = card.parentID, let above = try self.card(parent), above.deletedAt == nil { card = above }
    return card.id
  }

  /// 会话归哪件事：绑着它的叶子（`Card.piSessionID`）与叶子的顶层任务，按会话 id；没绑着任务的不在其中。唯一的规则，
  /// 等你的计数与报给 Cue 的变化（`cueChanges`）都读它：没删除的任务，做完了的也算（它的问题没答就还是在等你）；
  /// 一个会话绑着几件时只归最近修改的那件。
  func sessionOwners(_ sessionIDs: [String]) throws -> [String: (task: Card, leaf: Card)] {
    guard !sessionIDs.isEmpty else { return [:] }
    let leaves = try select(
      Card.self, where: "piSessionID IN (SELECT value FROM json_each(?)) AND todoAt IS NOT NULL AND deletedAt IS NULL",
      [JSONColumn.encode(sessionIDs)], orderBy: "modifiedAt DESC, id")
    var owners: [String: (task: Card, leaf: Card)] = [:]
    for leaf in leaves where owners[leaf.piSessionID!] == nil {
      guard let task = try find(Card.self, try topTask(of: leaf.id)) else { continue }
      owners[leaf.piSessionID!] = (task, leaf)
    }
    return owners
  }
}
