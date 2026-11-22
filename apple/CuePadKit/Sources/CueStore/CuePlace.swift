import Foundation

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

  static func capture(task: UUID?, wake: CueWake?, in db: SQLite) throws -> [String: CuePlace] {
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
    return places
  }
}

extension CueMessage {
  public func place(session: String) -> CuePlace? { places[CuePlace.key(session: session)] }
  public func place(task: UUID) -> CuePlace? { places[CuePlace.key(task: task)] }
}
