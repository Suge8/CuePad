import Foundation

/// 此刻参与工作的 Agent 数：主会话按 sessionID 去重（同一会话可被几件任务引用），
/// 思考、执行、压缩与等子代理的主会话各算一个；子代理读所属主会话的权威名册，运行与审查中各算一个。
/// 名册由接入按各家身份去重，不按显示名合并：两个子代理可以同名。Cue 本身不在看板会话里，不另加一。
enum CueAgents {
  static func count(in work: [CueWork]) -> Int {
    sessions(in: work).reduce(0) { $0 + $1.activeAgentCount }
  }

  static func sessions(in work: [CueWork]) -> [PiSessionState] {
    let sessions = Dictionary(
      work.flatMap { item -> [PiSessionState] in
        switch item {
        case .task(let task): task.leaves.compactMap(\.session)
        case .session(let session): [session]
        }
      }.filter { $0.state != .known(.ended) }.map { ($0.sessionID, $0) },
      uniquingKeysWith: { $0.modifiedAt >= $1.modifiedAt ? $0 : $1 })
    return Array(sessions.values)
  }
}

extension PiSessionState {
  public var activeAgentCount: Int {
    (runtimeState.isWorking ? 1 : 0) + runtimeSubagents.count { $0.phase == .known(.running) || $0.phase == .known(.review) }
  }
}
