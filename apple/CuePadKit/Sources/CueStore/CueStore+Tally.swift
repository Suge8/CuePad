import Foundation

/// 在管与等你：Cue 那一行、任务看板中间两列、小组件、实时活动与 Dock 角标读的同一份，只在这里算。
/// - 等你：Cue 带选项问你、还没结束的消息（`cueMessagesWaitingForYou`），加上会话里在等你回答的（`sessionsAskingYou`，规则在 `PiSessionState.asksYou`）。
///   一处在等就是一件：同一件任务上 Cue 在问、它的会话也在问，算两件。每件带上它落在哪件顶层任务上（消息的 `taskID`、会话绑着的叶子），没落在任务上的为 nil。
/// - 在管：进行中的顶层任务里，没有一件等你落在它上面的；先后同 `startedTasks`（最近开始的在前）。
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

  public var managing: [Card]
  public var waiting: [Wait]

  public init(managing: [Card], waiting: [Wait]) {
    self.managing = managing
    self.waiting = waiting
  }

  public static let empty = CueTally(managing: [], waiting: [])
}

extension CueStore {
  public func cueTally() throws -> CueTally {
    let messages = try cueMessagesWaitingForYou()
    let sessions = try sessionsAskingYou()
    let bound = try leaves(boundTo: sessions.map(\.sessionID))
    let waiting =
      try messages.map { CueTally.Wait.message($0, task: try $0.taskID.flatMap(topLevelTask)) }
      + sessions.map { CueTally.Wait.session($0, task: try bound[$0.sessionID].flatMap(topLevelTask)) }
    let held = Set(waiting.compactMap(\.task))
    return CueTally(managing: try startedTasks(topLevelOnly: true).filter { !held.contains($0.id) }, waiting: waiting)
  }

  /// 这件任务所在的顶层任务（上级不在库里或不可见时按顶层看待，同 `Card.parentID`）；任务不在库里为 nil。
  private func topLevelTask(_ id: UUID) throws -> UUID? {
    guard var card = try card(id) else { return nil }
    while let parent = card.parentID, let above = try self.card(parent), above.deletedAt == nil { card = above }
    return card.id
  }

  /// 绑着这些会话的叶子（`Card.piSessionID`），按会话 id。
  private func leaves(boundTo sessionIDs: [String]) throws -> [String: UUID] {
    guard !sessionIDs.isEmpty else { return [:] }
    let rows = try db.query(
      "SELECT piSessionID, id FROM cards WHERE deletedAt IS NULL AND piSessionID IN (SELECT value FROM json_each(?))",
      [JSONColumn.encode(sessionIDs)]
    ) { ($0.text(0), $0.uuid(1)) }
    return Dictionary(rows, uniquingKeysWith: { first, _ in first })
  }
}
