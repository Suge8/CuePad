import Foundation

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
