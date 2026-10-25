import Foundation

/// 一条对话写下那一刻，它提到的那几处的样子（`CueMessage.places`）：关联的那件任务（`taskID`）与叫醒 Cue 的那几处（`CueWake.sessionActivity`）。
/// 对话是记录：Cue 页按它画气泡下的任务行、结果卡与醒来那几行，不读那几处此刻的样子，之后改名、改状态、删掉都不变。
/// 写下时在同一个事务里取（`capture`），库升级 71 给之前的记录补也用它。名字是用户内容，加密同步。
/// 其他版本写来的没有这一份：界面只说是哪一类（"一个会话"、"一件任务"），不另查。
public struct CuePlace: Codable, Equatable, Sendable {
  /// 当时叫什么（会话名、任务标题）；空的为 nil
  public var name: String?
  /// 任务当时的状态；会话没有
  public var status: Open<TaskStatus>?
  /// 任务当时的子任务做完几个、共几个；没有子任务为 nil
  public var steps: Steps?

  public struct Steps: Codable, Equatable, Sendable {
    public var done: Int
    public var total: Int
  }

  static func key(session: String) -> String { "session:" + session }
  static func key(task: UUID) -> String { "task:" + task.uuidString.lowercased() }

  /// 那几处此刻的样子（写事务内调；记录已不在的不列）。
  static func capture(task: UUID?, wake: CueWake?, in db: SQLite) throws -> [String: CuePlace] {
    var sessions: [String] = [], tasks: [UUID] = task.map { [$0] } ?? []
    if case .sessionActivity(let stirs)? = wake {
      for stir in stirs {
        if let session = stir.session { sessions.append(session) } else if let task = stir.task { tasks.append(task) }
      }
    }
    var places: [String: CuePlace] = [:]
    for session in sessions {
      let title = try db.first("SELECT title FROM piSessionStates WHERE id = ?", [PiSessionState.recordID(sessionID: session)]) { $0.text(0) }
      if let title { places[key(session: session)] = CuePlace(name: title.isEmpty ? nil : title) }
    }
    for id in tasks {
      guard let card = try db.first("SELECT \(Card.selection) FROM cards WHERE id = ?", [id], { Card(row: $0) }) else { continue }
      let steps = try CueStore.subtaskProgress(scope: "AND parentID = ?", [id], in: db)[id]
      places[key(task: id)] = CuePlace(
        name: card.heading.isEmpty ? nil : card.heading, status: card.status.map(Open.known),
        steps: steps.map { Steps(done: $0.done, total: $0.total) })
    }
    return places
  }
}

extension CueMessage {
  /// 写下时这个会话（Pi 的会话 id）的样子；没记下为 nil。
  public func place(session: String) -> CuePlace? { places[CuePlace.key(session: session)] }
  /// 写下时这件任务的样子；没记下为 nil。
  public func place(task: UUID) -> CuePlace? { places[CuePlace.key(task: task)] }
}
