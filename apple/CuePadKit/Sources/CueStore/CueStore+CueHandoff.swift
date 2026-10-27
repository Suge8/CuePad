import Foundation

/// 会话此刻这次停下，Cue 把它的事交给了别处、那一处还没做完：会话歇着时，会话行与看板卡上近况那一句写在等它（`PiSessionListItem.handoff`），
/// 一眼看出有人管、在等谁。只从 Cue 每一轮的经过推（`cueMessages`）、读的时候对上那一处此刻的样子，不另存，也不截 Cue 的原话。
/// - 哪一轮：这次停下之后（`stateSince` 起）碰过它的最近一轮——它叫醒的（`CueWake.sessionActivity`），或这一轮的动作落在它上面；
///   取其中第一处交出去的地方（对别的会话说话、开工、新建任务，`handing`）。Cue 只看了看、没交出去的不算，近况照旧是会话自己最后那句回答。
/// - 还在等：交给的会话还有活（`PiWorkState.hasPendingWork`：在跑或在等回答），交给的任务还没完成、没进回收站；做完了就不再写，
///   等 Cue 醒来再处理（不然"等它做完"挂在一件已经做完的事上）。名字是那一处此刻的，改过名照新的写。
/// 这里只推事实；什么时候显示（Cue 值班时歇着，不是待回复、有新回复）只看会话显示的状态（App 的 `PiProgress.handoff`），不在这里再判一遍。
public struct CueHandoff: Equatable, Sendable {
  /// 怎么交出去的（对它说话、开工、新建）：界面画与 Cue 页经过里同一个动作图标
  public let kind: PiChatMessage.Tools.Kind
  /// 那一处此刻叫什么（会话名或任务标题）
  public let name: String
  /// 交给的是一件任务，否则是另一个会话：不点名的那句按它写
  public let task: Bool
}

extension CueStore {
  /// 往回只看 Cue 最近这么多轮：列表每读一次都要推一遍，歇了好几天的会话不该让它把几天的经过全解一遍；交出去总在停下后不久，
  /// 之后又有这么多轮没再碰它，那件事也早不是近况了。
  static let handoffWindow = 60

  /// 把事交出去的动作
  private static let handing: Set<PiChatMessage.Tools.Kind> = [.talk, .start, .add]

  /// 这些会话里停着（`settled`）、这次停下 Cue 交出去的那一处还没做完的，按 Pi 的会话 id。
  func handoffs(_ states: [PiSessionState]) throws -> [String: CueHandoff] {
    let settled = states.filter { $0.state == .known(.settled) }
    guard let since = settled.map(\.stateSince).min() else { return [:] }
    // 一轮的经过是没有正文的那一行
    let rounds = try select(
      CueMessage.self, where: "createdAt >= ? AND author IN ('note', 'round') AND text = ''", [since], orderBy: "createdAt DESC, rowid DESC",
      limit: Self.handoffWindow)
    let away: [String: CueActivity.Touch] = settled.reduce(into: [:]) { away, session in
      guard let round = rounds.first(where: { $0.createdAt >= session.stateSince && $0.concerns(session) }) else { return }
      away[session.sessionID] = CueActivity.touches(round.tools).first { Self.handing.contains($0.kind) && $0.session != session.id }
    }
    let pending = try pendingNames(Array(away.values))
    return away.compactMapValues { touch in
      (touch.task ?? touch.session).flatMap { pending[$0] }.map { CueHandoff(kind: touch.kind, name: $0, task: touch.task != nil) }
    }
  }

  /// 这几处里还没做完的此刻叫什么，按会话记录 id 或任务 id：会话还有活，任务还没完成、没进回收站。
  private func pendingNames(_ touches: [CueActivity.Touch]) throws -> [UUID: String] {
    let sessions = touches.compactMap { $0.task == nil ? $0.session : nil }, tasks = touches.compactMap(\.task)
    var names: [UUID: String] = [:]
    if !sessions.isEmpty {
      for state in try select(PiSessionState.self, where: "id IN (SELECT value FROM json_each(?))", [Self.idList(sessions)])
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
  /// 这一轮叫醒它的有这个会话，或这一轮做成的动作落在它上面。
  fileprivate func concerns(_ session: PiSessionState) -> Bool {
    if case .sessionActivity(let stirs)? = wake, stirs.contains(where: { $0.session == session.sessionID }) { return true }
    return tools?.items.contains { $0.session == session.id && !$0.failed } == true
  }
}
