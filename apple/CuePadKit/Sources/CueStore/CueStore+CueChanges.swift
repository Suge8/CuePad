import CueText
import Foundation

extension CueStore {
  /// 构成 Cue 的变化的那几列被写时（本机写入与同步落库一样），那一行盖上新序号（触发器见 `Schema+Indexes`）。Cue 按它分新旧，不按事件时刻：事件可能晚到（机器忙、从别的设备同步来），时刻早于上次醒来。
  public func lastWrite() throws -> Int { try db.first("SELECT seq FROM writeCounter") { Int($0.int(0)) } ?? 0 }

  /// 子任务完成从 `marks.tasks` 之后算（Cue 接着开下一步）；整件完成不报——不是 Cue 做完的就是他点的，没人再用的会话已随之结束。等子代理停住按时刻算，序号是会话记录的，判新旧只看时刻。等子代理本身不是变化：子代理的结果交回、会话为它跑完那一轮歇下才报。
  /// 会话停着（`SessionState.atStop`）：Cue 开的这一轮报给它定谁接手；他开的（`hisTurn`）已当场留给他回（`leaveHisStops`），Cue 之后看一眼再定收不收回、推不推进，停下时他在场（`SessionPresence`）就先不报、记进 `held`。管理器把上次的 `held` 交回来：等他离开，会话还停在那一次就作为变化报给 Cue。
  public func cueChanges(after marks: CueMarks, held: [String: Date] = [:], at now: Date = .now) throws -> CueChanges {
    var held = held
    let tasks = try topTasks(where: "(t.completedAt IS NULL OR t.writeSeq > ?) AND \(Self.hasSession)", [marks.tasks])
    var changes: [CueChange] = []
    let leaves = try tasks.flatMap { task in try leaves(of: task).map { (task: task, leaf: $0) } }
    var sessions = try sessionStates(leaves.compactMap(\.leaf.piSessionID))
    // 按状态索引的排序取：缺省的 rowid 排序会扫遍几千条已结束的会话
    for session in try select(SessionState.self, where: Self.isLoose("piSessionStates"), orderBy: "stateSince DESC, id") {
      sessions[session.sessionID] = session
    }
    let owners = try sessionOwners(Array(sessions.keys))
    let cardSeqs = try writeSeqs(of: .cards, "id", (leaves.map(\.leaf.id) + tasks.map(\.id)).map { $0.uuidString.lowercased() })
    let sessionSeqs = try writeSeqs(of: .piSessionStates, "sessionID", Array(sessions.keys))
    func seq(_ card: Card) -> Int { cardSeqs[card.id.uuidString.lowercased()] ?? 0 }
    func report(_ session: SessionState, seq: Int, task: Card?, leaf: Card?) throws {
      guard let change = try sessionChange(session, seq: seq, task: task, leaf: leaf) else { return }
      if session.atStop, try hisStop(session.sessionID) != nil { held[session.sessionID] = session.stateSince } else { changes.append(change) }
    }
    func stall(_ session: SessionState, seq: Int, task: Card?, leaf: Card?) throws {
      guard let at = session.stallsAt, at <= now, marks.stalls.map({ at > $0 }) ?? true else { return }
      // 他发起的那一轮不报：Cue 这会儿说不进去（`checkCueCanSpeak`），叫醒它只能干看
      guard try !hisTurn(session.sessionID) else { return }
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
      try report(session, seq: written, task: owner?.task, leaf: owner?.leaf)
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
    var result = try heldChanges(held, reported: Set(changes.compactMap(\.session?.sessionID)))
    result.due = (changes + result.due).sorted { $0.at < $1.at }
    return result
  }

  /// 它不随写入出现，值班的 Cue 管理器按它排好醒来的时刻。
  /// 不分在不在看板上（不在的到点醒来也没有变化，只多对一次账）。
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
    guard let kind else { return nil }
    return CueChange(
      kind: kind, task: task, leaf: leaf, session: session, byUser: try hisTurn(session.sessionID), at: session.stateSince, seq: seq,
      detail: detail, recap: session.recap, interrupted: session.state == .known(.interrupted))
  }

  /// 他发起的一轮停下时，CuePad 当场把这次停下留给他回（歇着、出错的待回复，在等回答的成了他的拍板），不等 Cue 醒来判断。Cue 开的那一轮停下仍报给 Cue 定（`cueChanges`）。返回的序号下次从它之后算：Cue 收回的不会再留回去。值班的管理器每次对账先做，Cue 在跑一轮也不等。
  public func leaveHisStops(after mark: Int) throws -> (mark: Int, left: UUID?) {
    try write {
      let latest = try lastWrite()
      guard latest > mark else { return (latest, nil) }
      let stopped = try select(SessionState.self, where: "state IN (\(sqlList(WorkState.allCases.filter(\.isStopped)))) AND writeSeq > ?", [mark])
      let his = try stopped.filter { try $0.atStop && hisTurn($0.sessionID) }
      return (latest, try putLeft(his) ? CueState.recordID : nil)
    }
  }

  /// 会话最近这一轮有他开轮的正证据（`turnOpener`，机器消息开的跟着它之前那句）。停下归谁只认这一处。
  private func hisTurn(_ sessionID: String) throws -> Bool { try turnOpener(sessionID) == .user }

  private func hisStop(_ sessionID: String) throws -> SessionPresence? {
    guard try hisTurn(sessionID) else { return nil }
    return try presence(in: sessionID)
  }

  private func presence(in sessionID: String) throws -> SessionPresence? {
    let viewing = try viewers().contains { $0.sessionIDs.contains(sessionID) }
    // 窗口内有明确人类来源的话（从晚到早）；缺来源证据不等于他说过。
    let said = try select(
      ChatMessage.self, where: "sessionID = ? AND role = '\(ChatRole.user.rawValue)' AND at > ?",
      [sessionID, timing.now() - SessionPresence.window], orderBy: "at DESC")
    let sources = try deliverySources(among: said.compactMap(\.deliveryID))
    let spokeAt = said.first { $0.source(in: sources) == .user }?.at
    return viewing || spokeAt != nil ? SessionPresence(viewing: viewing, spokeAt: spokeAt) : nil
  }

  private func heldChanges(_ held: [String: Date], reported: Set<String>) throws -> CueChanges {
    var result = CueChanges(due: [], held: [:], lapse: nil)
    guard !held.isEmpty else { return result }
    let sessions = try select(SessionState.self, where: "sessionID IN (SELECT value FROM json_each(?))", [JSONColumn.encode(held.keys.sorted())])
    let seqs = try writeSeqs(of: .piSessionStates, "sessionID", sessions.map(\.sessionID))
    let owners = try sessionOwners(sessions.map(\.sessionID))
    for session in sessions where session.stateSince.stored == held[session.sessionID]?.stored && session.atStop {
      let owner = owners[session.sessionID]
      guard let change = try sessionChange(session, seq: seqs[session.sessionID] ?? 0, task: owner?.task, leaf: owner?.leaf) else { continue }
      if let presence = try hisStop(session.sessionID) {
        result.held[session.sessionID] = session.stateSince
        if let lapse = presence.lapse { result.lapse = min(result.lapse ?? lapse, lapse) }
      } else if !reported.contains(session.sessionID) {
        result.due.append(change)
      }
    }
    return result
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

  /// 请求的动作在变化里的说法（说的话没送到另报 `undelivered`，不经这里）。
  private static func action(_ mode: Open<DeliveryMode>) -> String {
    switch mode.known {
    case .start: "开工"
    case .config: "换模型"
    case .stop, .stopTurn: "停下"
    case .end: "结束"
    default: mode.rawValue
    }
  }

  /// Cue 已经知道这些请求没送到：说话工具当场报给了它，且收到报告的那一轮好好做完了（值班的管理器记下，`CueKeeper`）。
  /// 之后不再作为变化报给它（`CueChange.Kind.undelivered`）。本机列：管理器与它的工具在同一台 Mac 上。
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
    // 读的是失败了的请求，到没到过服务器不会再改变它们：不依赖同步元数据
    try db.untracked(.syncRecords) {
      try db.query(
        "SELECT \(R.selection), writeSeq FROM \(R.table.rawValue) WHERE \(condition) ORDER BY \(orderBy)", arguments
      ) { (R(row: $0), Int($0.int($0.index(of: "writeSeq")!))) }
    }
  }
}
