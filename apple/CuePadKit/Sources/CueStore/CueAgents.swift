import Foundation

/// 参与工作的 Agent 数只按这里算（名牌、灵动岛读的那个数）：同一会话挂在几件事上只算一次、取最新的那条，结束了的不算。
/// 名册由接入按各家身份去重，不按显示名合并：两个子代理可以同名。
public enum CueAgents {
  public static func count(in work: [CueWork]) -> Int {
    sessions(in: work).reduce(0) { $0 + $1.activeAgentCount }
  }

  public static func sessions(in work: [CueWork]) -> [SessionState] {
    let sessions = Dictionary(
      work.flatMap { item -> [SessionState] in
        switch item {
        case .task(let task): task.leaves.compactMap(\.session)
        case .session(let session): [session]
        }
      }.filter { $0.state != .known(.ended) }.map { ($0.sessionID, $0) },
      uniquingKeysWith: { $0.modifiedAt >= $1.modifiedAt ? $0 : $1 })
    return Array(sessions.values)
  }
}

extension SessionState {
  public var activeAgentCount: Int {
    (runtimeState.isWorking ? 1 : 0) + runtimeSubagents.count { $0.phase == .known(.running) || $0.phase == .known(.review) }
  }
}
