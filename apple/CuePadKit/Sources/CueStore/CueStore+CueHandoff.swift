import Foundation

/// 只推事实；什么时候显示（Cue 值班时歇着，不是待回复、有新回复）只看会话显示的状态（App 的 `SessionProgress.handoff`），不在这里再判一遍。
/// 只从 Cue 每一轮的经过推（`cueMessages`）、读的时候对上那一处此刻的样子，不另存，也不截 Cue 的原话。
/// 交给的任务做完了就不再写，等 Cue 醒来再处理（不然“等它做完”挂在一件已经做完的事上）。Cue 只看了看、没交出去的不算，近况照旧是会话自己最后那句回答。
public struct CueHandoff: Equatable, Sendable {
  public let kind: ChatMessage.Tools.Kind
  public let place: UUID
  public let name: String
  public let task: Bool
}

extension CueStore {
  /// 往回只看 Cue 最近这么多轮：列表每读一次都要推一遍，歇了好几天的会话不该让它把几天的经过全解一遍；交出去总在停下后不久，
  /// 之后又有这么多轮没再碰它，那件事也早不是近况了。
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
