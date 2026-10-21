import CueText
import Foundation

extension CueStore {
  /// 本机最近一次写入的序号：构成 Cue 的变化的那几列被写时（本机写入与同步落库一样），那一行盖上新序号（触发器见 `Schema+Indexes`）。
  /// Cue 按它分新旧，不按事件时刻：事件可能晚到（机器忙、从别的设备同步来），时刻早于上次醒来。
  public func lastWrite() throws -> Int { try db.first("SELECT seq FROM writeCounter") { Int($0.int(0)) } ?? 0 }

  /// 写入序号 `marks` 之后有会话的事与不归没做完的事的活会话（`isLoose`）里的变化，按事件时刻从早到晚：会话歇下（最后一轮的回答读到之后，见 `sessionChange`）、等回答、出错，Cue 发起的请求没能执行
  /// （这些从 `marks.sessions` 之后算；还没开成会话的事也报），叶子或任务完成（从 `marks.tasks` 之后算），
  /// 等子代理停住（停住的时刻在 `marks.stalls` 之后、不晚于 `now`；序号是会话记录的）。等子代理本身不是变化：子代理的结果交回、会话为它跑完那一轮歇下才报。
  /// 会话里用户说的话不另报：他那一轮歇下时变化标着这一轮是他说的（`CueChange.byUser`）。
  /// 会话停着（`CueChange.isStop`）归谁接手只在这里定（`hisStop`）：Cue 开的这一轮归 Cue；他开的（机器消息开的跟着它之前那句，见 `turnOpener`）、停下时他在场（`SessionPresence`）归他，
  /// 不报给 Cue、记进 `held`。管理器把上次的 `held` 交回来：归他的停下等他离开，会话还停在那一次、也没留给他（`CueLeft`）就作为变化报给 Cue。
  public func cueChanges(after marks: CueMarks, held: [String: Date] = [:], at now: Date = .now) throws -> CueChanges {
    var held = held
    let tasks = try topTasks(where: "(t.completedAt IS NULL OR t.writeSeq > ?) AND \(Self.hasSession)", [marks.tasks])
    var changes: [CueChange] = []
    let leaves = try tasks.flatMap { task in try leaves(of: task).map { (task: task, leaf: $0) } }
    // 要看的会话：这些事的叶子绑着的，与不归没做完的事的活会话；各归哪件事只看 `sessionOwners`
    var sessions = try sessionStates(leaves.compactMap(\.leaf.piSessionID))
    // 按状态索引的排序取：缺省的 rowid 排序会扫遍几千条已结束的会话
    for session in try select(PiSessionState.self, where: Self.isLoose("piSessionStates"), orderBy: "stateSince DESC, id") {
      sessions[session.sessionID] = session
    }
    let owners = try sessionOwners(Array(sessions.keys))
    let cardSeqs = try writeSeqs(of: .cards, "id", (leaves.map(\.leaf.id) + tasks.map(\.id)).map { $0.uuidString.lowercased() })
    let sessionSeqs = try writeSeqs(of: .piSessionStates, "sessionID", Array(sessions.keys))
    func seq(_ card: Card) -> Int { cardSeqs[card.id.uuidString.lowercased()] ?? 0 }
    func report(_ session: PiSessionState, seq: Int, task: Card?, leaf: Card?) throws {
      guard let change = try sessionChange(session, seq: seq, task: task, leaf: leaf) else { return }
      if change.isStop, try hisStop(session.sessionID) != nil { held[session.sessionID] = session.stateSince } else { changes.append(change) }
    }
    func stall(_ session: PiSessionState, seq: Int, task: Card?, leaf: Card?) {
      guard let at = session.stallsAt, at <= now, marks.stalls.map({ at > $0 }) ?? true else { return }
      let running = session.subagents.filter(\.isRunning).map { $0.action.isEmpty ? $0.name : "\($0.name)：\($0.action)" }
      changes.append(CueChange(
        kind: .stalled, task: task, leaf: leaf, session: session, at: at, seq: seq, detail: running.joined(separator: "；"), recap: session.recap))
    }
    for task in tasks where task.completedAt != nil && seq(task) > marks.tasks {
      changes.append(CueChange(kind: .done, task: task, at: task.completedAt!, seq: seq(task), recap: try latestRecap(of: task.id)))
    }
    for (task, leaf) in leaves where leaf.id != task.id {
      guard let done = leaf.completedAt, seq(leaf) > marks.tasks else { continue }
      changes.append(CueChange(kind: .done, task: task, leaf: leaf, at: done, seq: seq(leaf), recap: leaf.piSessionID.flatMap { sessions[$0] }?.recap))
    }
    // 一个会话一处变化：算在它归的那件事上，没归哪件事的算在它自己上
    for session in sessions.values.sorted(by: { $0.sessionID < $1.sessionID }) {
      guard let written = sessionSeqs[session.sessionID] else { continue }
      let owner = owners[session.sessionID]
      stall(session, seq: written, task: owner?.task, leaf: owner?.leaf)
      guard written > marks.sessions else { continue }
      try report(session, seq: written, task: owner?.task, leaf: owner?.leaf)
    }
    let failed = try selectWritten(
      DeliveryRequest.self, where: "origin = '\(DeliveryOrigin.cue.rawValue)' AND status = 'failed' AND cueToldAt IS NULL AND writeSeq > ?",
      [marks.sessions], orderBy: "writeSeq")
    for (request, written) in failed {
      // 没带卡的失败算在会话归的那件事上（同上）
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

  /// `now` 之后最早的一次等子代理停住（`PiSessionState.stallsAt`）：它不随写入出现，值班的 Cue 管理器按它排好醒来的时刻。
  /// 不分在不在看板上（不在的到点醒来也没有变化，只多对一次账）。
  public func nextCueStall(after now: Date) throws -> Date? {
    try select(PiSessionState.self, where: "state = ?", [PiWorkState.delegating.rawValue])
      .compactMap(\.stallsAt).filter { $0 > now }.min()
  }

  /// 会话停在的状态是一处变化时（歇下、被打断、等回答、出错）的那条变化；在跑、已结束为 nil。
  /// 歇下要等最后一轮的回答读到才算（`PiSessionState.answered`）：状态由 Agent 报，问答由 Mac 读会话文件写，两路先后不定
  /// （Claude Code 的轮末标记写在报歇下的钩子之后）。读到时收尾时刻一变，这一行盖上新序号，变化随之出现。
  private func sessionChange(_ session: PiSessionState, seq: Int, task: Card?, leaf: Card?) throws -> CueChange? {
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
      kind: kind, task: task, leaf: leaf, session: session, byUser: try turnOpener(session.sessionID) == .user, at: session.stateSince, seq: seq,
      detail: detail, recap: session.recap, interrupted: session.state == .known(.interrupted))
  }

  /// 停着的会话此刻归他（返回他的在场）：这一轮不是 Cue 开的（`turnOpener`），他在场；归 Cue 为 nil。谁接手只认这一处。
  func hisStop(_ sessionID: String) throws -> SessionPresence? {
    guard try turnOpener(sessionID) != .cue else { return nil }
    return try presence(in: sessionID)
  }

  /// 他此刻在不在会话里（`SessionPresence`）；不在场为 nil。
  private func presence(in sessionID: String) throws -> SessionPresence? {
    let viewing = try viewers().contains { $0.sessionID == sessionID }
    // 他一方说的、窗口内的话（从晚到早），去掉 Cue 发进去的（`PiChatMessage.saidByCue`）
    let said = try select(
      PiChatMessage.self, where: "sessionID = ? AND role = '\(PiChatRole.user.rawValue)' AND at > ?",
      [sessionID, timing.now() - SessionPresence.window], orderBy: "at DESC")
    let cueSent = try cueSentDeliveries(among: said.compactMap(\.deliveryID))
    let spokeAt = said.first { !$0.saidByCue(cueSent) }?.at
    return viewing || spokeAt != nil ? SessionPresence(viewing: viewing, spokeAt: spokeAt) : nil
  }

  /// 归他的停下（会话 id → 那次停下的起点）此刻怎样了：会话动了（谁说了话、结束了）、不再停着（`CueChange.isStop`）或已留给他的不再记；
  /// 还归他的接着记，给出最早会到点的离开时刻；他离开了的作为变化报给 Cue（`reported` 里已有这个会话的变化就不重复）。
  private func heldChanges(_ held: [String: Date], reported: Set<String>) throws -> CueChanges {
    var result = CueChanges(due: [], held: [:], lapse: nil)
    guard !held.isEmpty else { return result }
    let left = try cueState()?.left ?? []
    let sessions = try select(PiSessionState.self, where: "sessionID IN (SELECT value FROM json_each(?))", [JSONColumn.encode(held.keys.sorted())])
    let seqs = try writeSeqs(of: .piSessionStates, "sessionID", sessions.map(\.sessionID))
    let owners = try sessionOwners(sessions.map(\.sessionID))
    for session in sessions where session.stateSince.stored == held[session.sessionID]?.stored && !left.contains(where: { $0.holds(for: session) }) {
      let owner = owners[session.sessionID]
      guard let change = try sessionChange(session, seq: seqs[session.sessionID] ?? 0, task: owner?.task, leaf: owner?.leaf), change.isStop else { continue }
      if let presence = try hisStop(session.sessionID) {
        result.held[session.sessionID] = session.stateSince
        if let lapse = presence.lapse { result.lapse = min(result.lapse ?? lapse, lapse) }
      } else if !reported.contains(session.sessionID) {
        result.due.append(change)
      }
    }
    return result
  }

  /// 请求带着的叶子与它的顶层任务；卡不在了、不是任务（已删、改回灵感）为空。
  private func failedLeaf(_ card: UUID) throws -> [(task: Card?, leaf: Card?)] {
    guard let leaf = try find(Card.self, card), leaf.deletedAt == nil, leaf.isTask,
      let task = try find(Card.self, try topTask(of: leaf.id)), task.deletedAt == nil
    else { return [] }
    return [(task, leaf)]
  }

  func sessionState(_ sessionID: String) throws -> PiSessionState? {
    try find(PiSessionState.self, PiSessionState.recordID(sessionID: sessionID))
  }

  /// 请求的动作在变化里的说法（说的话没送到另报 `undelivered`，不经这里）。
  private static func action(_ mode: Open<DeliveryMode>) -> String {
    switch mode.known {
    case .start: "开工"
    case .config: "换模型"
    case .stop: "停下"
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
        "UPDATE deliveryRequests SET cueToldAt = ? WHERE id IN (SELECT value FROM json_each(?)) AND status = 'failed'",
        [Date.stamp, Self.idList(requests)])
    }
  }

  /// 任务（自己或它的步骤）的会话里最近有动静的那个的摘要；没有会话为 nil。
  private func latestRecap(of task: UUID) throws -> PiRecap? { try latestSession(of: task)?.recap }

  /// 任务（自己或它的步骤）绑着的会话里最近有动静的那个；没有为 nil。
  func latestSession(of task: UUID) throws -> PiSessionState? {
    try select(
      PiSessionState.self,
      where: "sessionID IN (SELECT piSessionID FROM cards WHERE (id = ?1 OR parentID = ?1) AND todoAt IS NOT NULL AND piSessionID IS NOT NULL)",
      [task], orderBy: "stateSince DESC, id", limit: 1
    ).first
  }

  /// 这些行的写入序号，按 `key` 列（同一个键有几行取最新的）。
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
    try db.query(
      "SELECT \(R.columns.joined(separator: ", ")), writeSeq FROM \(R.table.rawValue) WHERE \(condition) ORDER BY \(orderBy)", arguments
    ) { (R(row: $0), Int($0.int(Int32(R.columns.count)))) }
  }
}
