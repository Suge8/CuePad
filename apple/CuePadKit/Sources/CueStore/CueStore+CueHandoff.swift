import Foundation

public struct CueHandoff: Equatable, Sendable {
  public let kind: ChatMessage.Tools.Kind
  public let place: UUID
  public let name: String
  public let task: Bool
}

extension CueStore {
  static let handoffWindow = 60

  private static let handing: Set<ChatMessage.Tools.Kind> = [.talk, .start, .add]

  public func handoffs(_ states: [SessionState]) throws -> [String: CueHandoff] {
    let settled = states.filter { $0.state == .known(.settled) }
    guard let since = settled.map(\.stateSince).min() else { return [:] }
    let rounds = try select(
      CueMessage.self, where: "createdAt >= ? AND author IN ('note', 'round') AND text = ''", [since], orderBy: "createdAt DESC, rowid DESC",
      limit: Self.handoffWindow)
    let away: [String: CueActivity.Touch] = settled.reduce(into: [:]) { away, session in
      guard let round = rounds.first(where: { $0.createdAt >= session.stateSince && $0.concerns(session) }) else { return }
      away[session.sessionID] = CueActivity.touches(round.tools).first { Self.handing.contains($0.kind) && $0.session != session.id }
    }
    let pending = try pendingNames(Array(away.values))
    return away.compactMapValues { touch in
      (touch.task ?? touch.session).flatMap { place in pending[place].map { CueHandoff(kind: touch.kind, place: place, name: $0, task: touch.task != nil) } }
    }
  }

  private func pendingNames(_ touches: [CueActivity.Touch]) throws -> [UUID: String] {
    let sessions = touches.compactMap { $0.task == nil ? $0.session : nil }, tasks = touches.compactMap(\.task)
    var names: [UUID: String] = [:]
    if !sessions.isEmpty {
      for state in try select(SessionState.self, where: "id IN (SELECT value FROM json_each(?))", [Self.idList(sessions)])
      where state.state.known?.hasPendingWork == true { names[state.id] = state.title }
    }
    if !tasks.isEmpty {
      for card in try select(Card.self, where: "id IN (SELECT value FROM json_each(?)) AND completedAt IS NULL AND deletedAt IS NULL", [Self.idList(tasks)]) {
        names[card.id] = card.heading
      }
    }
    return names
  }
}

extension CueMessage {
  fileprivate func concerns(_ session: SessionState) -> Bool {
    if case .sessionActivity(let stirs)? = wake, stirs.contains(where: { $0.session == session.sessionID }) { return true }
    return tools?.items.contains { $0.session == session.id && !$0.failed } == true
  }
}
