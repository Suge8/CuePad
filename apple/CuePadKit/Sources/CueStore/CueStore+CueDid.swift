import Foundation

/// Cue 对会话此刻这次停下做过的最近一件事：会话歇着、Cue 已接手时，会话行与看板卡上近况那一句换成它（`PiSessionListItem.cueDid`），
/// 一眼看出有人管。只从 Cue 的对话推（`cueMessages`），不另存。
/// 取这次停下之后（`stateSince` 起）碰过它的最近一轮——它叫醒的（`CueWake.sessionActivity`），或这一轮的动作落在它上面（`Tools.Item.session`）：
/// 这一轮说的头一句话，没说话是最要紧的那个动作（`CueActivity.lead`，如转给了另一个会话）。
/// 这里只推事实；什么时候显示（Cue 值班时歇着，不是待回复、有新回复）只看会话显示的状态（App 的 `PiProgress.cue`），不在这里再判一遍。
public enum CueDid: Equatable, Sendable {
  case said(String)
  case touched(CueActivity.Touch)
}

extension CueStore {
  /// 往回只看 Cue 最近这么多条：列表每读一次都要推一遍，歇了好几天的会话不该让它把几天的对话全解一遍；接手一次停下总在停下后不久，
  /// 之后又有这么多条 Cue 的话还没再碰它，那句也早不是近况了。
  static let cueDidWindow = 60

  /// 这些会话里停着（`settled`）的那几个各自的 `CueDid`，按 Pi 的会话 id；Cue 还没碰过这次停下的不在内。
  func cueDid(_ states: [PiSessionState]) throws -> [String: CueDid] {
    let settled = states.filter { $0.state == .known(.settled) }
    guard let since = settled.map(\.stateSince).min() else { return [:] }
    var rounds: [(row: CueMessage, said: String?)] = []
    let recent = try select(
      CueMessage.self, where: "createdAt >= ? AND author IN ('note', 'round', 'cue')", [since], orderBy: "createdAt DESC, rowid DESC", limit: Self.cueDidWindow)
    for message in recent.reversed() {
      if message.text.isEmpty, message.author != .known(.cue) {
        rounds.append((message, nil))
      } else if let last = rounds.indices.last, rounds[last].said == nil, !message.text.isEmpty {
        rounds[last].said = message.text
      }
    }
    return settled.reduce(into: [:]) { did, session in
      guard let round = rounds.last(where: { $0.row.createdAt >= session.stateSince && $0.row.concerns(session) }) else { return }
      did[session.sessionID] = round.said.map(CueDid.said) ?? CueActivity.lead(round.row.tools).map(CueDid.touched)
    }
  }
}

extension CueMessage {
  /// 这一轮叫醒它的有这个会话，或这一轮做成的动作落在它上面。
  fileprivate func concerns(_ session: PiSessionState) -> Bool {
    if case .sessionActivity(let stirs)? = wake, stirs.contains(where: { $0.session == session.sessionID }) { return true }
    return tools?.items.contains { $0.session == session.id && !$0.failed } == true
  }
}
