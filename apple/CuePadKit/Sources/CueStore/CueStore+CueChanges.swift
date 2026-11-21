import CueText
import Foundation

extension CueStore {
  public func lastWrite() throws -> Int { try db.first("SELECT seq FROM writeCounter") { Int($0.int(0)) } ?? 0 }

  public func cueChanges(after marks: CueMarks, at now: Date = .now) throws -> [CueChange] {
    let tasks = try topTasks(where: "(t.completedAt IS NULL OR t.writeSeq > ?) AND \(Self.hasSession)", [marks.tasks])
    var changes: [CueChange] = []
    let leaves = try tasks.flatMap { task in try leaves(of: task).map { (task: task, leaf: $0) } }
    var sessions = try sessionStates(leaves.compactMap(\.leaf.piSessionID))
    for session in try select(SessionState.self, where: Self.isLoose("piSessionStates"), orderBy: "stateSince DESC, id") {
      sessions[session.sessionID] = session
    }
    let owners = try sessionOwners(Array(sessions.keys))
    let cardSeqs = try writeSeqs(of: .cards, "id", (leaves.map(\.leaf.id) + tasks.map(\.id)).map { $0.uuidString.lowercased() })
    let sessionSeqs = try writeSeqs(of: .piSessionStates, "sessionID", Array(sessions.keys))
    func seq(_ card: Card) -> Int { cardSeqs[card.id.uuidString.lowercased()] ?? 0 }
    func stall(_ session: SessionState, seq: Int, task: Card?, leaf: Card?) throws {
      guard let at = session.stallsAt, at <= now, marks.stalls.map({ at > $0 }) ?? true else { return }
      guard !session.hisTurn else { return }
      let running = session.subagents.filter(\.isRunning).map { $0.action.isEmpty ? $0.name : "\($0.name)：\($0.action)" }
      changes.append(CueChange(
        kind: .stalled, task: task, leaf: leaf, session: session, at: at, seq: seq, detail: running.joined(separator: "；"), recap: session.recap))
    }
    for (task, leaf) in leaves where leaf.id != task.id && task.completedAt == nil {
      guard let done = leaf.completedAt, seq(leaf) > marks.tasks else { continue }
      changes.append(CueChange(kind: .done, task: task, leaf: leaf, at: done, seq: seq(leaf), recap: leaf.piSessionID.flatMap { sessions[$0] }?.recap))
    }
    for session in sessions.values.sorted(by: { $0.sessionID < $1.sessionID }) {
      guard let written = sessionSeqs[session.sessionID] else { continue }
      let owner = owners[session.sessionID]
      try stall(session, seq: written, task: owner?.task, leaf: owner?.leaf)
      guard written > marks.sessions else { continue }
      if let change = try sessionChange(session, seq: written, task: owner?.task, leaf: owner?.leaf) { changes.append(change) }
    }
    let failed = try selectWritten(
      DeliveryRequest.self, where: "origin = '\(DeliveryOrigin.cue.rawValue)' AND status = '\(DeliveryStatus.failed.rawValue)' AND cueToldAt IS NULL AND writeSeq > ?",
      [marks.sessions], orderBy: "writeSeq")
    for (request, written) in failed {
      let pairs = try request.cardID.map(failedLeaf)
        ?? request.target.ref.flatMap { ref in sessions[ref].map { _ in [(task: owners[ref]?.task, leaf: owners[ref]?.leaf)] } } ?? []
      let at = request.resultReceivedAt ?? request.completedAt ?? request.createdAt
      let spoken = request.mode.known.map(DeliveryMode.toSession.contains) == true
      let reason = request.failure ?? DeliveryRequest.unexplainedFailure
      let session = try request.target.ref.flatMap(sessionState)
      for pair in pairs {
        changes.append(CueChange(
          kind: spoken ? .undelivered : .failed, task: pair.task, leaf: pair.leaf, session: session, at: at, seq: written,
          detail: spoken ? reason : "\(Self.action(request.mode))：\(reason)", recap: session?.recap))
      }
    }
    return changes.sorted { $0.at < $1.at }
  }

  public func nextCueStall(after now: Date) throws -> Date? {
    try select(SessionState.self, where: "state = ?", [WorkState.delegating.rawValue])
      .compactMap { session -> Date? in
        guard let due = session.stallsAt, let until = session.runtimeUntil, due < until else { return nil }
        return due
      }.filter { $0 > now }.min()
  }

  /// 报告事件不替当前运行背书：presence 可以晚于新报告到，`session.runtimeState` 仍保留未确认。
  /// 歇下要等最后一轮的回答读到才算（`SessionState.answered`）：状态由 Agent 报，问答由 Mac 读会话文件写，两路先后不定
  /// （Claude Code 的轮末标记写在报歇下的钩子之后）。读到时收尾时刻一变，这一行盖上新序号，变化随之出现。
  private func sessionChange(_ session: SessionState, seq: Int, task: Card?, leaf: Card?) throws -> CueChange? {
    let (kind, detail): (CueChange.Kind?, String?) =
      switch session.state.known {
      case .settled where !session.answered: (nil, nil)
      case .settled, .interrupted: (.settled, nil)
      case .waitingForUser: (.waitingForUser, session.question?.text ?? session.detail)
      case .error: (.failed, session.detail)
      default: (nil, nil)
      }
    guard let kind, !session.hisTurn else { return nil }
    return CueChange(
      kind: kind, task: task, leaf: leaf, session: session, at: session.stateSince, seq: seq,
      detail: detail, recap: session.recap, interrupted: session.state == .known(.interrupted))
  }

  public func leaveHisStops(after mark: Int) throws -> Int {
    try write {
      let latest = try lastWrite()
      guard latest > mark else { return latest }
      let stopped = try select(SessionState.self, where: "state IN (\(sqlList(WorkState.allCases.filter(\.isStopped)))) AND writeSeq > ?", [mark])
      let his = stopped.filter { $0.atStop && $0.hisTurn }
      try putLeft(his)
      return latest
    }
  }

  private func failedLeaf(_ card: UUID) throws -> [(task: Card?, leaf: Card?)] {
    guard let leaf = try find(Card.self, card), leaf.deletedAt == nil, leaf.isTask,
      let task = try find(Card.self, try topTask(of: leaf.id)), task.deletedAt == nil
    else { return [] }
    return [(task, leaf)]
  }

  public func sessionState(_ sessionID: String) throws -> SessionState? {
    try find(SessionState.self, SessionState.recordID(sessionID: sessionID))
  }

  private static func action(_ mode: Open<DeliveryMode>) -> String {
    switch mode.known {
    case .start: "开工"
    case .config: "换模型"
    case .stop: "停下"
    case .end: "结束"
    default: mode.rawValue
    }
  }

  public func markCueTold(_ requests: [UUID]) throws {
    guard !requests.isEmpty else { return }
    try write {
      try db.run(
        "UPDATE deliveryRequests SET cueToldAt = ? WHERE id IN (SELECT value FROM json_each(?)) AND status = '\(DeliveryStatus.failed.rawValue)'",
        [Date.stamp, Self.idList(requests)])
    }
  }

  func latestSession(of task: UUID) throws -> SessionState? {
    try select(
      SessionState.self,
      where: "sessionID IN (SELECT piSessionID FROM cards WHERE (id = ?1 OR parentID = ?1) AND todoAt IS NOT NULL AND piSessionID IS NOT NULL)",
      [task], orderBy: "stateSince DESC, id", limit: 1
    ).first
  }

  private func writeSeqs(of table: Table, _ key: String, _ keys: [String]) throws -> [String: Int] {
    guard !keys.isEmpty else { return [:] }
    return Dictionary(
      try db.query(
        "SELECT \(key), MAX(writeSeq) FROM \(table.rawValue) WHERE \(key) IN (SELECT value FROM json_each(?)) GROUP BY \(key)", [JSONColumn.encode(keys)]
      ) { ($0.text(0), Int($0.int(1))) },
      uniquingKeysWith: { first, _ in first })
  }

  private func selectWritten<R: Record>(
    _ type: R.Type, where condition: String, _ arguments: [any SQLBindable], orderBy: String
  ) throws -> [(R, Int)] {
    try db.untracked(.syncRecords) {
      try db.query(
        "SELECT \(R.selection), writeSeq FROM \(R.table.rawValue) WHERE \(condition) ORDER BY \(orderBy)", arguments
      ) { (R(row: $0), Int($0.int($0.index(of: "writeSeq")!))) }
    }
  }
}
