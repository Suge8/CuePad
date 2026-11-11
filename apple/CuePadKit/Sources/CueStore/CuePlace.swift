import Foundation

/// 对话是记录：Cue 页按它画气泡下的任务行、结果卡与醒来那几行，不读那几处此刻的样子，之后改名、改状态、删掉都不变。写下时在同一个事务里取（`capture`）。名字是用户内容，加密同步。
/// 其他版本写来的没有这一份：界面只说是哪一类（“一个会话”、“一件任务”），不另查。
public struct CuePlace: Codable, Equatable, Sendable {
  public var name: String?
  public var status: Open<TaskStatus>?
  public var steps: Steps?

  public struct Steps: Codable, Equatable, Sendable {
    public var done: Int
    public var total: Int
  }

  static func key(session: String) -> String { "session:" + session }
  static func key(task: UUID) -> String { "task:" + task.uuidString.lowercased() }
  static func key(project: UUID) -> String { "project:" + project.uuidString.lowercased() }

  static func capture(task: UUID?, wake: CueWake?, project: UUID? = nil, in db: SQLite) throws -> [String: CuePlace] {
    var sessions: [String] = [], tasks: [UUID] = task.map { [$0] } ?? []
    if case .sessionActivity(let stirs)? = wake {
      for stir in stirs {
        if let session = stir.session { sessions.append(session) } else if let task = stir.task { tasks.append(task) }
      }
    }
    var places: [String: CuePlace] = [:]
    for session in sessions {
      let title = try db.first("SELECT title FROM piSessionStates WHERE id = ?", [SessionState.recordID(sessionID: session)]) { $0.text(0) }
      if let title { places[key(session: session)] = CuePlace(name: title.isEmpty ? nil : title) }
    }
    for id in tasks {
      guard let card = try db.first("SELECT \(Card.selection) FROM cards WHERE id = ?", [id], { Card(row: $0) }) else { continue }
      let steps = try CueStore.subtaskProgress(scope: "AND parentID = ?", [id], in: db)[id]
      places[key(task: id)] = CuePlace(
        name: card.heading.isEmpty ? nil : card.heading, status: card.status.map(Open.known),
        steps: steps.map { Steps(done: $0.done, total: $0.total) })
    }
    if let project, let name = try db.first("SELECT name FROM projects WHERE id = ?", [project], { $0.text(0) }) {
      places[key(project: project)] = CuePlace(name: name)
    }
    return places
  }
}

extension CueMessage {
  public func place(session: String) -> CuePlace? { places[CuePlace.key(session: session)] }
  public func place(task: UUID) -> CuePlace? { places[CuePlace.key(task: task)] }

  /// `choices` 是写下时的字，作答与记下的回答都按它。
  public var shownChoices: [String]? { choices.map { $0.map(shownChoice) } }

  public func shownChoice(_ choice: String) -> String {
    CueAsked.shownChoice(choice, choices: choices, asked: asked, places: places)
  }
}

extension CueAsked {
  public static func shownChoice(_ choice: String, choices: [String]?, asked: CueAsked?, places: [String: CuePlace]) -> String {
    guard let ask = asked?.ask.known, let index = choices?.firstIndex(of: choice) else { return choice }
    guard index > 0 else { return CueAsk.once }
    let project = asked?.project.map { id in places[CuePlace.key(project: id)]?.name.map { Project.shownName(id: id, name: $0) } ?? "" }
    return ask.always(in: project) ?? choice
  }
}
