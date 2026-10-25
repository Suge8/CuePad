import Foundation

/// 一条对话写下那一刻，它提到的那几处的样子（`CueMessage.places`）：关联的那件任务（`taskID`）、提问的范围（`CueAsked.project`，选项照它的名字写）
/// 与叫醒 Cue 的那几处（`CueWake.sessionActivity`）。
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
  static func key(project: UUID) -> String { "project:" + project.uuidString.lowercased() }

  /// 那几处此刻的样子（写事务内调；记录已不在的不列）。`project` 是提问的范围（`CueAsked.project`），选项按它的名字写。
  static func capture(task: UUID?, wake: CueWake?, project: UUID? = nil, in db: SQLite) throws -> [String: CuePlace] {
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
    if let project, let name = try db.first("SELECT name FROM projects WHERE id = ?", [project], { $0.text(0) }) {
      places[key(project: project)] = CuePlace(name: name)
    }
    return places
  }
}

extension CueMessage {
  /// 写下时这个会话（Pi 的会话 id）的样子；没记下为 nil。
  public func place(session: String) -> CuePlace? { places[CuePlace.key(session: session)] }
  /// 写下时这件任务的样子；没记下为 nil。
  public func place(task: UUID) -> CuePlace? { places[CuePlace.key(task: task)] }

  /// 选项给人看的样子（这台设备的语言，与 `choices` 一项对一项）：照类别与范围由 `CueAsk` 写出；`choices` 是写下时的字，作答与记下的回答都按它。
  public var shownChoices: [String]? { choices.map { $0.map(shownChoice) } }

  /// 存下的一项（`choices` 之一、`answer`）给人看的样子；不是提问、认不出类别的照存下的显示。
  public func shownChoice(_ choice: String) -> String {
    CueAsked.shownChoice(choice, choices: choices, asked: asked, places: places)
  }
}

extension CueAsked {
  /// 见 `CueMessage.shownChoice`；通知服务扩展照同步记录的几个字段调。
  public static func shownChoice(_ choice: String, choices: [String]?, asked: CueAsked?, places: [String: CuePlace]) -> String {
    guard let ask = asked?.ask.known, let index = choices?.firstIndex(of: choice) else { return choice }
    guard index > 0 else { return CueAsk.once }
    let project = asked?.project.map { id in places[CuePlace.key(project: id)]?.name.map { Project.shownName(id: id, name: $0) } ?? "" }
    return ask.always(in: project) ?? choice
  }
}
