import Foundation

extension CueStore {
  func writeSessionState(
    sessionID: String, hostID: String, bootID: String?, content: SessionSnapshot, catalog: AgentCatalog?, writesCatalog: Bool, notify: AlertKind?
  ) throws {
    try write {
      let now = Date.stamp
      var record = SessionState(content, over: nil, hostID: hostID, bootID: bootID, at: now)
      record.catalogID = catalog?.id
      if writesCatalog, let catalog { try writeCatalog(catalog) }
      if let notify {
        var event = record
        event.runtimeUntil = now
        record.notify = try push(notify, event)
      }
      let assignments = SessionState.columns.dropFirst()
        .filter { $0 != "createdAt" && $0 != "createdForTaskID" && $0 != "restoredAt" && $0 != "notify" && !SessionState.recapColumns.contains($0) }
        .map { ["turnStartedAt", "turnDelivery", "turnByCue"].contains($0) ? "\($0) = COALESCE(excluded.\($0), piSessionStates.\($0))" : "\($0) = excluded.\($0)" }
        .joined(separator: ", ")
      let placeholders = SessionState.columns.map { _ in "?" }.joined(separator: ", ")
      try db.run(
        """
        INSERT INTO piSessionStates (\(SessionState.columns.joined(separator: ", "))) VALUES (\(placeholders))
        ON CONFLICT(id) DO UPDATE SET \(assignments),
          notify = CASE
            WHEN excluded.notify IS NOT NULL THEN excluded.notify
            WHEN piSessionStates.notify IS NOT NULL AND piSessionStates.state = excluded.state THEN piSessionStates.notify
          END
        """, record.bindings)
      if let process = content.process {
        try db.run(
          "INSERT OR REPLACE INTO piProcesses (sessionID, pid, startedAt) VALUES (?, ?, ?)", [sessionID, Int64(process.pid), process.startedAt])
      }
      if content.launchToken != nil { try claimLaunchedCards() }
      try dropUnusedCatalogs(host: hostID)
    }
  }

  func loseSessionState(host: String, sessionID: String, bootID: String?, at now: Date) throws {
    try write {
      try close(where: "id = ?", [SessionState.recordID(sessionID: sessionID)], boot: bootID, at: now)
      try db.run("DELETE FROM piProcesses WHERE sessionID = ?", [sessionID])
      try dropUnusedCatalogs(host: host)
    }
  }

  func endSessionState(host: String, sessionID: String, bootID: String?, at now: Date, confirming requests: Set<UUID>) throws {
    try write {
      try db.run(
        "UPDATE piSessionStates SET state = ?, bootID = ?, \(Self.cleared), stateSince = ?, modifiedAt = ? WHERE id = ? AND state != ?",
        [WorkState.ended.rawValue, bootID, now, Date.stamp, SessionState.recordID(sessionID: sessionID), WorkState.ended.rawValue])
      try db.run("DELETE FROM piProcesses WHERE sessionID = ?", [sessionID])
      try db.run("""
        UPDATE deliveryRequests SET status = 'succeeded', failure = NULL, completedAt = ?1, modifiedAt = MAX(modifiedAt + 1, ?1)
        WHERE id IN (SELECT value FROM json_each(?2)) AND mode = 'end' AND targetRef = ?3 AND hostID = ?4 AND handledBy = ?4
          AND status IN (\(DeliveryStatus.claimedSQL))
        """, [Date.stamp, Self.idList(requests), sessionID, host])
      try dropUnusedCatalogs(host: host)
    }
  }

  func reconcileSessionStates(host: String, bootID: String?, running: (SessionProcess) -> Bool, at now: Date) throws -> [String: (state: WorkState, times: SessionTimes)] {
    try write {
      let before = try db.query(
        // `+hostID`：不走 hostID 索引（这台 Mac 的会话几乎就是全部），改走 state 索引只读没收尾的那几条
        "SELECT sessionID, state, stateSince, busySince, bootID, hosted FROM piSessionStates WHERE +hostID = ? AND \(WorkState.outsideSQL(WorkState.closed))", [host]
      ) { row in
        (id: row.text(0), state: WorkState(rawValue: row.text(1)), times: SessionTimes(stateSince: row.date(2), busySince: row.dateOrNil(3)),
         boot: row.textOrNil(4), hosted: !row.isNull(5) && row.int(5) == 1)
      }
      let processes = try db.query(
        "SELECT p.sessionID, p.pid, p.startedAt FROM piProcesses p JOIN piSessionStates s ON s.sessionID = p.sessionID WHERE s.hostID = ?",
        [host]
      ) { (sessionID: $0.text(0), process: SessionProcess(pid: Int32($0.int(1)), startedAt: $0.int(2))) }
      let recorded = Set(processes.map(\.sessionID))
      let alive = Set(processes.filter { running($0.process) }.map(\.sessionID))
      if !alive.isEmpty {
        try db.run("UPDATE piSessionStates SET bootID = ?, modifiedAt = ? WHERE hostID = ? AND sessionID IN (SELECT value FROM json_each(?))",
                   [bootID, Date.stamp, host, JSONColumn.encode(alive.sorted())])
      }
      let gone = recorded.subtracting(alive).union(before.compactMap { record in
        guard let bootID, record.boot != bootID, !recorded.contains(record.id),
          record.boot != nil || (record.hosted && (record.state == .settled || record.state == .error)) else { return nil }
        return record.id
      })
      let open = Dictionary(before.compactMap { record -> (String, (WorkState, SessionTimes))? in
        guard alive.contains(record.id) || (bootID != nil && record.boot == bootID && !gone.contains(record.id)) else { return nil }
        return record.state.map { (record.id, ($0, record.times)) }
      }) { $1 }
      guard !gone.isEmpty else { return open }
      let among = "(SELECT value FROM json_each(?))", goneList = JSONColumn.encode(gone.sorted())
      try close(where: "hostID = ? AND sessionID IN \(among)", [host, goneList], boot: bootID, at: now)
      try db.run("DELETE FROM piProcesses WHERE sessionID IN \(among)", [goneList])
      try dropUnusedCatalogs(host: host)
      return open
    }
  }

  private func close(where condition: String, _ arguments: [any SQLBindable], boot: String?, at now: Date) throws {
    let failed = "(hosted = 1 AND state = '\(WorkState.error.rawValue)')"
    let state = """
      CASE WHEN \(Self.hadWork) THEN '\(WorkState.interrupted.rawValue)' WHEN \(failed) THEN state
        WHEN hosted = 1 THEN '\(WorkState.settled.rawValue)' ELSE '\(WorkState.ended.rawValue)' END
      """
    let kept = "((state = '\(WorkState.settled.rawValue)' AND NOT \(Self.hadWork)) OR \(failed))"
    try db.run(
      """
      UPDATE piSessionStates SET stateSince = CASE WHEN \(kept) THEN stateSince ELSE ? END,
        state = \(state), bootID = ?, \(Self.cleared), detail = CASE WHEN \(failed) THEN detail END, modifiedAt = ?
      WHERE \(WorkState.outsideSQL(WorkState.closed)) AND \(condition)
      """, [now, boot, Date.stamp] + arguments)
  }

  private static let cleared = "detail = NULL, question = NULL, notify = NULL, busySince = NULL, subagents = NULL, failure = NULL"

  private static let hadWork = """
    (state IN (\(WorkState.pendingWorkSQL))
      OR EXISTS (SELECT 1 FROM json_each(subagents) WHERE json_extract(value, '$.state') = '\(SubagentPhase.running.rawValue)'))
    """

  func deleteUnindexedHostedStates(host: String, agent: AgentKind, except live: Set<String>) throws {
    let arguments: [any SQLBindable] = [host, agent.rawValue, JSONColumn.encode(live.sorted())]
    try write {
      try db.run(
        """
        DELETE FROM piSessionStates WHERE +hostID = ? AND agent = ? AND hosted = 1 AND \(WorkState.outsideSQL([.ended]))
          AND sessionID NOT IN (SELECT id FROM piSessions) AND sessionID NOT IN (SELECT value FROM json_each(?))
        """,
        arguments)
      try dropUnusedCatalogs(host: host)
    }
  }

  func deleteSessionState(host: String, sessionID: String) throws {
    try write {
      try db.run("DELETE FROM piSessionStates WHERE id = ?", [SessionState.recordID(sessionID: sessionID)])
      try db.run("DELETE FROM piProcesses WHERE sessionID = ?", [sessionID])
      try dropUnusedCatalogs(host: host)
    }
  }
}

/// pid 加启动时刻（微秒）——pid 会被复用，启动时刻对上才是同一个进程。只记在本机表 `piProcesses`，不同步。
public struct SessionProcess: Equatable, Sendable {
  public var pid: Int32
  public var startedAt: Int64

  public init(pid: Int32, startedAt: Int64) {
    self.pid = pid
    self.startedAt = startedAt
  }

  #if os(macOS)
  public static func running(pid: Int32) -> SessionProcess? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let start = info.kp_proc.p_un.__p_starttime
    return SessionProcess(pid: pid, startedAt: Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec))
  }

  public var isRunning: Bool { Self.running(pid: pid) == self }
  #endif
}

extension SessionState {
  public init(_ content: SessionSnapshot, over stored: SessionState?, hostID: String, bootID: String?, at now: Date) {
    self = stored ?? SessionState(
      id: SessionState.recordID(sessionID: content.sessionID), sessionID: content.sessionID, hostID: hostID, title: "", projectID: nil,
      state: .known(content.state), detail: nil, folder: nil, lastPrompt: nil, lastReply: nil, question: nil, notify: nil,
      stateSince: now, busySince: nil, createdAt: now, modifiedAt: now)
    self.hostID = hostID
    title = content.title
    projectID = content.projectID
    state = .known(content.state)
    detail = content.detail
    folder = content.folder
    question = content.question
    stateSince = content.times.stateSince
    busySince = content.times.busySince
    launchToken = content.launchToken
    hosted = content.hosted
    subagents = content.subagents
    model = content.modelState.model
    thinking = content.modelState.thinking
    fast = content.modelState.fast
    context = content.context
    agent = .known(content.agent)
    turnStartedAt = content.turnStartedAt ?? stored?.turnStartedAt
    turnOpener = content.turnOpener ?? stored?.turnOpener
    failure = content.state == .error ? content.failure.map(Open.known) : nil
    self.bootID = bootID
  }

  public func connected() -> SessionState {
    var state = self
    state.runtimeUntil = .distantFuture
    return state
  }
}

public struct SessionSnapshot: Paced {
  public let sessionID: String
  public var state: WorkState
  public var detail: String?
  public var title = ""
  public var directory: String?
  public var projectID: UUID?
  public var question: Question?
  public var failure: FailureKind?
  public var times: SessionTimes
  public var turnStartedAt: Date?
  public var turnOpener: TurnOpener?
  public var launchToken: String?
  public var hosted = false
  public var subagents: [SubagentState] = []
  public var modelState = ModelState()
  public var context: ContextUsage?
  public var commands: [SlashCommand] = []
  public var agent = AgentKind.pi
  public var process: SessionProcess?

  public init(sessionID: String, state: WorkState, times: SessionTimes) {
    self.sessionID = sessionID
    self.state = state
    self.times = times
  }

  mutating func keepingUnknown(from previous: SessionSnapshot) {
    turnStartedAt = turnStartedAt ?? previous.turnStartedAt
    turnOpener = turnOpener ?? previous.turnOpener
    launchToken = launchToken ?? previous.launchToken
    context = context ?? previous.context
    projectID = projectID ?? previous.projectID
  }

  var folder: String? { directory.flatMap(CueStore.folderName(ofWorkingDirectory:)) }
  var isWorking: Bool { state.isWorking }

  func catalog(host: String, at now: Date) -> AgentCatalog? {
    guard !modelState.models.isEmpty || !commands.isEmpty else { return nil }
    return AgentCatalog(host: host, models: modelState.models, commands: commands, at: now)
  }

  func catalogDiffers(from written: SessionSnapshot?) -> Bool {
    written.map { $0.modelState.models != modelState.models || $0.commands != commands } ?? true
  }

  var steady: SessionSnapshot {
    var steady = self
    steady.state = .settled
    steady.detail = nil
    steady.launchToken = nil
    steady.context = nil
    steady.turnStartedAt = nil
    steady.subagents = subagents.map(\.shape)
    return steady
  }
}
