import Foundation

/// Cue 把会话此刻这次停下的事交给了别处（对另一个会话说话，或开工、新建一件任务）：会话歇着时，会话行与看板卡上近况那一句写它在等哪一处做完
/// （`PiSessionListItem.handoff`），一眼看出有人管、在等什么。只从 Cue 每一轮的经过推（`cueMessages`），不另存，也不截 Cue 的原话。
/// 取这次停下之后（`stateSince` 起）碰过它的最近一轮——它叫醒的（`CueWake.sessionActivity`），或这一轮的动作落在它上面（`Tools.Item.session`）——
/// 里第一处交出去的地方。Cue 只看了看、没交出去的不算：那时近况照旧是会话自己最后那句回答。
/// 这里只推事实；什么时候显示（Cue 值班时歇着，不是待回复、有新回复）只看会话显示的状态（App 的 `PiProgress.handoff`），不在这里再判一遍。
public struct CueHandoff: Equatable, Sendable {
  /// 交给的那一处写下那一刻叫什么（会话名或任务标题）
  public let name: String
  /// 交给的是一件任务（开工、新建），否则是另一个会话
  public let task: Bool
}

extension CueStore {
  /// 往回只看 Cue 最近这么多轮：列表每读一次都要推一遍，歇了好几天的会话不该让它把几天的经过全解一遍；交出去总在停下后不久，
  /// 之后又有这么多轮没再碰它，那件事也早不是近况了。
  static let handoffWindow = 60

  /// 这些会话里停着（`settled`）、这次停下 Cue 已交给别处的那几个，按 Pi 的会话 id。
  func handoffs(_ states: [PiSessionState]) throws -> [String: CueHandoff] {
    let settled = states.filter { $0.state == .known(.settled) }
    guard let since = settled.map(\.stateSince).min() else { return [:] }
    // 一轮的经过是没有正文的那一行
    let rounds = try select(
      CueMessage.self, where: "createdAt >= ? AND author IN ('note', 'round') AND text = ''", [since], orderBy: "createdAt DESC, rowid DESC",
      limit: Self.handoffWindow)
    return settled.reduce(into: [:]) { handoffs, session in
      guard let round = rounds.first(where: { $0.createdAt >= session.stateSince && $0.concerns(session) }),
        let away = CueActivity.touches(round.tools).first(where: { Self.handing.contains($0.kind) && $0.session != session.id })
      else { return }
      handoffs[session.sessionID] = CueHandoff(name: away.name, task: away.session == nil)
    }
  }

  /// 把事交出去的动作：对别的会话说话、开工、新建任务
  private static let handing: Set<PiChatMessage.Tools.Kind> = [.talk, .start, .add]
}

extension CueMessage {
  /// 这一轮叫醒它的有这个会话，或这一轮做成的动作落在它上面。
  fileprivate func concerns(_ session: PiSessionState) -> Bool {
    if case .sessionActivity(let stirs)? = wake, stirs.contains(where: { $0.session == session.sessionID }) { return true }
    return tools?.items.contains { $0.session == session.id && !$0.failed } == true
  }
}
