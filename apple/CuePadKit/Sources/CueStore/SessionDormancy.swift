import Foundation

/// 会话闲置（唯一规则，`CueStore.dormancy` 读出此刻的那一份）：没结束、停着没在问（歇着或出错），进入这个状态已超过 `after`，
/// 也不是 Cue 留给你回的那次停下（`CueLeft`，待回复属于等你，不收）。闲置的会话不算活跃：看板与 Cue 管的不归没做完的事的活会话（`CueStore.isLoose`）、
/// 会话条与会话列表的"现在"都不列它，它收进"更早"（`PiSessionScope.earlier`）。会话一有新动静（状态变了，`stateSince` 前进）自然回来，不用谁去清。
/// 只是活动信号：不改任务的状态，绑着它的任务照旧在它的列（`CueBoardLeaf.isActive` 不读它：看板的列是"Cue 在做"的投影，读了它任务就落回待办）。
/// 阈值取 2 小时：够一次午饭或会议回来接着做，又不让一早随手开的会话占着看板一整天（同类的 Agent Kanban 也取 2 小时）。
public struct SessionDormancy: Sendable, Equatable {
  public static let after: TimeInterval = 2 * 60 * 60
  static let resting: [PiWorkState] = [.settled, .error]

  /// 早于它进入歇着或出错的会话闲置。
  public let cutoff: Date
  /// Cue 留给你回的那几次停下（会话 id 与停下的时刻）：Cue 不值班时为空，待回复不成立。
  let left: [CueLeft]

  /// 这个会话此刻闲置。
  public func holds(_ session: PiSessionState) -> Bool {
    guard let state = session.state.known, Self.resting.contains(state), session.stateSince < cutoff else { return false }
    return !left.contains { $0.sessionID == session.sessionID && $0.since.stored == session.stateSince.stored }
  }

  /// 同 `holds` 的 SQL 条件（`alias` 是会话记录表）。
  func sql(_ alias: String) -> String {
    let kept = left.map { "'\("\($0.sessionID):\($0.since.stored)".replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ", ")
    return """
      (\(alias).state IN (\(sqlList(Self.resting))) AND \(alias).stateSince < \(cutoff.stored)
        AND (\(alias).sessionID || ':' || \(alias).stateSince) NOT IN (\(kept)))
      """
  }
}

extension CueStore {
  /// 此刻的闲置规则（`SessionDormancy`）。在订阅里读时登记下一个会话跨过阈值的时刻，到点重读（`expire(at:)`）：
  /// 没有写入也会变，看板、会话条与"更早"到点就换，不轮询。
  public func dormancy() throws -> SessionDormancy {
    let cutoff = timing.now().addingTimeInterval(-SessionDormancy.after)
    let next = try db.first(
      "SELECT MIN(stateSince) FROM piSessionStates WHERE state IN (\(sqlList(SessionDormancy.resting))) AND stateSince >= ?", [cutoff]
    ) { $0.dateOrNil(0) } ?? nil
    if let next { expire(at: next.addingTimeInterval(SessionDormancy.after)) }
    return SessionDormancy(cutoff: cutoff, left: try cueDuty()?.left ?? [])
  }
}
